require 'thor'
require 'thor/group'
require 'fileutils'
require 'pathname'

require "forklift"

module Forklift
  class UI < ::Thor
    map "-T" => :list, "-v" => :version

    # If a task is not found on Thor::Runner, method missing is invoked and
    # Thor::Runner is then responsable for finding the task in all classes.
    #
    def method_missing(meth, *args)
      meth = meth.to_s
      klass, task = Thor::Util.find_class_and_task_by_namespace(meth)
      args.unshift(task) if task
      klass.start(args, :shell => self.shell)
    end

    def self.banner(task, all = false, subcommand = false)
      "forklift " + task.formatted_usage(self, all, subcommand)
    end

    desc :start, "Start master"
    def start
      Forklift::Master.new.start.join
    end

    class Remote < Thor
      namespace :remote

      desc "#{namespace}:start", "Start"
      def start
        puts "Start"
      end
    end
  end
end
