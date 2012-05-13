# Forklift

Forklift is a process manager with middleware allowing it to be used for building a multitude of background
processing applications. It can be controlled using AMQP, has process managing and reporting over AMQP,
autoscaling based on machine usage, pure unix forking model, socket based IPC, and an auto-healing highly redundent design.

_The design goal is to be the perfect replacement for Resque, Sidekiq, and the like._

## Installation

Add this line to your application's Gemfile:

    gem 'forklift'

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install forklift

## Usage

    $ forklift help

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Added some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request

## Author

- [Ivan Vanderbyl](http://twitter.com/ivanvanderbyl)


