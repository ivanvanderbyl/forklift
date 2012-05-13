module Forklift
  class Worker

    attr_reader :number

    def initialize(number)
      @number = number
      puts "Worker #{number} spawned"
    end

    # worker objects may be compared to just plain Integers
    def ==(other_nr) # :nodoc:
      @number == other_nr
    end

    def nr
      @number
    end

    def close # :nodoc:
      @tmp.close if @tmp
    end
  end
end
