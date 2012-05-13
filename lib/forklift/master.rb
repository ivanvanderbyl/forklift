require "logger"
require "socket"

module Forklift
  class Master

    # This hash maps PIDs to Workers
    WORKERS = {}

    attr_reader :pid, :logger
    attr_accessor :worker_processes, :master_pid

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
      self.worker_processes = 2
      @logger = Logger.new($stdout)
    end

    def start
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
      proc_name 'master'
      logger.info "master process ready" # test_exec.rb relies on this message

      begin
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
      init_worker_process(worker)

      logger.info "worker=#{worker.nr} ready"

      begin

        logger.debug "Worker loop"

      rescue => e
        redo if nr < 0 && (Errno::EBADF === e || IOError === e) # reopen logs
        Forklift.log_error(@logger, "listen loop error", e) if worker
        exit
      end while worker
    end

    def spawn_missing_workers
      worker_nr = -1
      until (worker_nr += 1) == self.worker_processes
        WORKERS.value?(worker_nr) and next
        worker = Worker.new(worker_nr)
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

    def proc_name(tag)
      $0 = ([ File.basename(START_CTX[0]), tag
            ]).concat(START_CTX[:argv]).join(' ')
    end

    def redirect_io(io, path)
      File.open(path, 'ab') { |fp| io.reopen(fp) } if path
      io.sync = true
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
