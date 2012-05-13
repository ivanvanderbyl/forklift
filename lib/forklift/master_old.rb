require "logger"

module Forklift
  class Master
    attr_accessor :app, :timeout, :worker_processes,
                :before_fork, :after_fork, :before_exec,
                :listener_opts, :preload_app,
                :reexec_pid, :orig_app, :init_listeners,
                :master_pid, :config, :ready_pipe, :user

    attr_reader :pid, :logger

    # This hash maps PIDs to Workers
    WORKERS = {}

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
    end

    def start
      # this pipe is used to wake us up from select(2) in #join when signals
      # are trapped.  See trap_deferred.
      init_self_pipe!

      # setup signal handlers before writing pid file in case people get
      # trigger happy and send signals as soon as the pid file exists.
      # Note that signals don't actually get handled until the #join method
      QUEUE_SIGS.each { |sig| trap(sig) { SIG_QUEUE << sig; awaken_master } }
      trap(:CHLD) { awaken_master }

      self.master_pid = $$

      @logger = Logger.new($stdout)
      @timeout = 10

      logger.info "Starting master"

      @worker_processes = 2

      spawn_missing_workers

      self
    end

    # monitors children and receives signals forever
    # (or until a termination signal is sent).  This handles signals
    # one-at-a-time time and we'll happily drop signals in case somebody
    # is signalling us too often.
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

        when :QUIT # graceful shutdown
          break
        when :TERM, :INT # immediate shutdown
          stop(false)
          break
        when :USR1 # rotate logs
          logger.info "master done reopening logs"
          kill_each_worker(:USR1)
        when :USR2 # exec binary, stay alive in case something went wrong
          reexec
        end

      rescue => e
        Forklift.log_error(@logger, "master loop error", e)
      end while true
    end

    private

    def worker_loop(worker)
      ppid = master_pid
      ppid = master_pid
      init_worker_process(worker)
      nr = 0 # this becomes negative if we need to reopen logs
      # ready = l.dup

      # closing anything we IO.select on will raise EBADF
      trap(:USR1) { nr = -65536; SELF_PIPE[0].close rescue nil }
      trap(:QUIT) { worker = nil; LISTENERS.each { |s| s.close rescue nil }.clear }
      logger.info "worker=#{worker.nr} ready"

      begin
        nr < 0 and reopen_worker_logs(worker.nr)
        nr = 0

        logger.info "Working"

        EM.run {

        }

        ppid == Process.ppid or return

        # timeout used so we can detect parent death:
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
      proc_name "worker[#{worker.nr}]"
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
      until (worker_nr += 1) == @worker_processes
        WORKERS.value?(worker_nr) and next
        worker = Worker.new(worker_nr)
        # before_fork.call(self, worker)
        if pid = fork
          WORKERS[pid] = worker
        else
          after_fork_internal
          worker_loop(worker)
          exit
        end
      end
    rescue => e
      @logger.error(e) rescue nil
      exit!
    end


    def after_fork_internal
      @ready_pipe.close if @ready_pipe
      @ready_pipe = @init_listeners = @before_exec = @before_fork = nil

      srand # http://redmine.ruby-lang.org/issues/4338

      # The OpenSSL PRNG is seeded with only the pid, and apps with frequently
      # dying workers can recycle pids
      OpenSSL::Random.seed(rand.to_s) if defined?(OpenSSL::Random)
    end

    # wait for a signal hander to wake us up and then consume the pipe
    def master_sleep(sec)
      IO.select([ SELF_PIPE[0] ], nil, nil, sec) or return
      SELF_PIPE[0].kgio_tryread(11)
    end

    def awaken_master
      SELF_PIPE[1].kgio_trywrite('.') # wakeup master process from select
    end

    def proc_name(tag)
      $0 = ([ File.basename(START_CTX[0]), tag
            ]).concat(START_CTX[:argv]).join(' ')
    end

    def redirect_io(io, path)
      File.open(path, 'ab') { |fp| io.reopen(fp) } if path
      io.sync = true
    end

    def init_self_pipe!
      SELF_PIPE.each { |io| io.close rescue nil }
      SELF_PIPE.replace(Kgio::Pipe.new)
      SELF_PIPE.each { |io| io.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC) }
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
