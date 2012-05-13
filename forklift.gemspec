# -*- encoding: utf-8 -*-
require File.expand_path('../lib/forklift/version', __FILE__)

Gem::Specification.new do |gem|
  gem.authors       = ["Ivan Vanderbyl"]
  gem.email         = ["ivanvanderbyl@me.com"]
  gem.description   = %q{Forklift is a preforking, autoscaling process manager for building background processing applications}
  gem.summary       = %q{"Unicorn for background processing"}
  gem.homepage      = ""

  gem.files         = `git ls-files`.split($\)
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.name          = "forklifter"
  gem.require_paths = ["lib"]
  gem.version       = Forklift::VERSION

  gem.add_dependency 'activesupport', '~> 3.2.0'
  gem.add_dependency 'thor'
  gem.add_dependency 'eventmachine'
  gem.add_dependency 'kgio'
end
