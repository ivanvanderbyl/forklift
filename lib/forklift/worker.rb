module Forklift
  class Worker

    attr_reader :number, :logger

    def initialize(logger, number)
      @i = 0
      @number = number
      @tick = Time.now.to_i
      @logger = logger
      logger.debug "Worker #{number} spawned"
    end

    # worker objects may be compared to just plain Integers
    def ==(other_nr) # :nodoc:
      @number == other_nr
    end

    def tick=(int)
      @tick = int
    end

    def tick
      @tick
    end

    def nr
      @number
    end

    def close # :nodoc:
      @tmp.close if @tmp
    end

    def perform
      @i += 1
      logger.info "Working #{@i}"
      sleep 5
    end
  end
end
