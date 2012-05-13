require "logger"
require "socket"

module Forklift
  class Master

    # This hash maps PIDs to Workers
    WORKERS = {}

    attr_reader :pid, :logger
    attr_accessor :worker_processes, :master_pid, :reexec_pid, :timeout

    SELF_PIPE = []

    # signal queue used for self-piping
    SIG_QUEUE = []

    # list of signals we care about and trap in master.
    QUEUE_SIGS = [ :WINCH, :QUIT, :INT, :TERM, :USR1, :USR2, :HUP, :TTIN, :TTOU ]

    START_CTX = {
      :argv => ARGV.map { |arg| arg.dup },
      0 => $0.dup,
    }
    # We favor ENV['PWD'] since it is (usually) symlink aware for Capistrano
    # and like systems
    START_CTX[:cwd] = begin
      a = File.stat(pwd = ENV['PWD'])
      b = File.stat(Dir.pwd)
      a.ino == b.ino && a.dev == b.dev ? pwd : Dir.pwd
    rescue
      Dir.pwd
    end

    def initialize
      self.reexec_pid = 0
      self.worker_processes = 2
      @logger = Logger.new($stdout)
      @timeout = 100
    end

    def start
      init_self_pipe!
      # setup signal handlers before writing pid file in case people get
      # trigger happy and send signals as soon as the pid file exists.
      # Note that signals don't actually get handled until the #join method
      QUEUE_SIGS.each { |sig| trap(sig) { SIG_QUEUE << sig; awaken_master } }
      trap(:CHLD) { awaken_master }

      self.master_pid = $$

      logger.info "Starting master"

      spawn_missing_workers

      self
    end

    def join
      respawn = true
      last_check = Time.now

      proc_name 'master'
      logger.info "master process ready" # test_exec.rb relies on this message
      if @ready_pipe
        @ready_pipe.syswrite($$.to_s)
        @ready_pipe = @ready_pipe.close rescue nil
      end

      begin
        reap_all_workers

        case SIG_QUEUE.shift
        when nil
          # avoid murdering workers after our master process (or the
          # machine) comes out of suspend/hibernation
          if (last_check + @timeout) >= (last_check = Time.now)
            sleep_time = murder_lazy_workers
          else
            sleep_time = @timeout/2.0 + 1
            @logger.debug("waiting #{sleep_time}s after suspend/hibernation")
          end
          maintain_worker_count if respawn
          master_sleep(sleep_time)

        when :QUIT # graceful shutdown
          break
        when :TERM, :INT # immediate shutdown
          stop(false)
          break
        when :USR1 # rotate logs
          logger.info "master done reopening logs"
          kill_each_worker(:USR1)
        when :USR2 # exec binary, stay alive in case something went wrong
          # reexec
        end

      rescue => e
        Forklift.log_error(@logger, "master loop error", e)
      end while true

      stop # gracefully shutdown all workers on our way out
      logger.info "master complete"
      unlink_pid_safe(pid) if pid
    end

    private

    # wait for a signal hander to wake us up and then consume the pipe
    def master_sleep(sec)
      IO.select([ SELF_PIPE[0] ], nil, nil, sec) or return
      SELF_PIPE[0].kgio_tryread(11)
    end

    def awaken_master
      SELF_PIPE[1].kgio_trywrite('.') # wakeup master process from select
    end

    def worker_loop(worker)
      ppid = master_pid
      init_worker_process(worker)

      logger.info "worker=#{worker.number} ready"

      begin
        nr = 0
        worker.tick = Time.now.to_i

        logger.debug "Worker loop"
        sleep 5

        ppid == Process.ppid or return

        # timeout used so we can detect parent death:
        worker.tick = Time.now.to_i
        # ret = IO.select(l, nil, SELF_PIPE, @timeout) and ready = ret[0]
      rescue => e
        redo if nr < 0 && (Errno::EBADF === e || IOError === e) # reopen logs
        Forklift.log_error(@logger, "listen loop error", e) if worker
        exit
      end while worker
    end

    EXIT_SIGS = [ :QUIT, :TERM, :INT ]
    WORKER_QUEUE_SIGS = QUEUE_SIGS - EXIT_SIGS

    # gets rid of stuff the worker has no business keeping track of
    # to free some resources and drops all sig handlers.
    # traps for USR1, USR2, and HUP may be set in the after_fork Proc
    # by the user.
    def init_worker_process(worker)
      # we'll re-trap :QUIT later for graceful shutdown iff we accept clients
      EXIT_SIGS.each { |sig| trap(sig) { exit!(0) } }
      exit!(0) if (SIG_QUEUE & EXIT_SIGS)[0]
      WORKER_QUEUE_SIGS.each { |sig| trap(sig, nil) }
      trap(:CHLD, 'DEFAULT')
      SIG_QUEUE.clear
      proc_name "worker[#{worker.number}]"
      START_CTX.clear
      init_self_pipe!
      WORKERS.clear
      # after_fork.call(self, worker) # can drop perms
      # worker.user(*user) if user.kind_of?(Array) && ! worker.switched
      self.timeout /= 2.0 # halve it for select()
      @config = nil
      @after_fork = @listener_opts = @orig_app = nil
    end

    def spawn_missing_workers
      worker_nr = -1
      until (worker_nr += 1) == self.worker_processes
        WORKERS.value?(worker_nr) and next
        worker = Worker.new(logger, worker_nr)
        # before_fork.call(self, worker)
        if pid = fork
          WORKERS[pid] = worker
        else
          worker_loop(worker)
          exit
        end
      end
    rescue => e
      @logger.error(e) rescue nil
      exit!
    end

    def maintain_worker_count
      (off = WORKERS.size - worker_processes) == 0 and return
      off < 0 and return spawn_missing_workers
      WORKERS.dup.each_pair { |wpid,w|
        w.number >= worker_processes and kill_worker(:QUIT, wpid) rescue nil
      }
    end

    # forcibly terminate all workers that haven't checked in in timeout seconds.  The timeout is implemented using an unlinked File
    def murder_lazy_workers
      next_sleep = @timeout - 1
      now = Time.now.to_i
      WORKERS.dup.each_pair do |wpid, worker|
        tick = worker.tick
        0 == tick and next # skip workers that haven't processed any clients
        diff = now - tick
        tmp = @timeout - diff
        if tmp >= 0
          next_sleep > tmp and next_sleep = tmp
          next
        end
        next_sleep = 0
        logger.error "worker=#{worker.number} PID:#{wpid} timeout " \
                     "(#{diff}s > #{@timeout}s), killing"
        kill_worker(:KILL, wpid) # take no prisoners for timeout violations
      end
      next_sleep <= 0 ? 1 : next_sleep
    end

    def proc_name(tag)
      $0 = tag
      # $0 = ([ File.basename(START_CTX[0]), tag
      #       ]).concat(START_CTX[:argv]).join(' ')
    end

    def redirect_io(io, path)
      File.open(path, 'ab') { |fp| io.reopen(fp) } if path
      io.sync = true
    end

    # Terminates all workers, but does not exit master process
    def stop(graceful = true)
      limit = Time.now + timeout
      until WORKERS.empty? || Time.now > limit
        kill_each_worker(graceful ? :QUIT : :TERM)
        sleep(0.1)
        reap_all_workers
      end
      kill_each_worker(:KILL)
    end

    # delivers a signal to a worker and fails gracefully if the worker
    # is no longer running.
    def kill_worker(signal, wpid)
      Process.kill(signal, wpid)
      rescue Errno::ESRCH
        worker = WORKERS.delete(wpid) and worker.close rescue nil
    end

    # delivers a signal to each worker
    def kill_each_worker(signal)
      WORKERS.keys.each { |wpid| kill_worker(signal, wpid) }
    end

    def init_self_pipe!
      SELF_PIPE.each { |io| io.close rescue nil }
      SELF_PIPE.replace(Kgio::Pipe.new)
      SELF_PIPE.each { |io| io.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC) }
    end

    # reaps all unreaped workers
    def reap_all_workers
      begin
        wpid, status = Process.waitpid2(-1, Process::WNOHANG)
        wpid or return
        if reexec_pid == wpid
          logger.error "reaped #{status.inspect} exec()-ed"
          self.reexec_pid = 0
          self.pid = pid.chomp('.oldbin') if pid
          proc_name 'master'
        else
          worker = WORKERS.delete(wpid) and worker.close rescue nil
          m = "reaped #{status.inspect} worker=#{worker.number rescue 'unknown'}"
          status.success? ? logger.info(m) : logger.error(m)
        end
      rescue Errno::ECHILD
        break
      end while true
    end

    # unlinks a PID file at given +path+ if it contains the current PID
    # still potentially racy without locking the directory (which is
    # non-portable and may interact badly with other programs), but the
    # window for hitting the race condition is small
    def unlink_pid_safe(path)
      (File.read(path).to_i == $$ and File.unlink(path)) rescue nil
    end

    # returns a PID if a given path contains a non-stale PID file,
    # nil otherwise.
    def valid_pid?(path)
      wpid = File.read(path).to_i
      wpid <= 0 and return
      Process.kill(0, wpid)
      wpid
      rescue Errno::ESRCH, Errno::ENOENT
        # don't unlink stale pid files, racy without non-portable locking...
    end

  end
end
