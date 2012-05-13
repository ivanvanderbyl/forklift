module Forklift
  class Worker

    attr_reader :number

    def initialize(number)
      @number = number
      @tick = Time.now.to_i
      puts "Worker #{number} spawned"
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
  end
end
