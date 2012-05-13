require 'fcntl'
require 'etc'
require 'stringio'
require 'kgio'
require 'eventmachine'

module Forklift
  autoload :VERSION, 'forklift/version'

  autoload :Master, 'forklift/master'
  autoload :Worker, 'forklift/worker'

  def self.log_error(logger, prefix, exc)
    message = exc.message
    message = message.dump if /[[:cntrl:]]/ =~ message
    logger.error "#{prefix}: #{message} (#{exc.class})"
    exc.backtrace.each { |line| logger.error(line) }
  end
end
