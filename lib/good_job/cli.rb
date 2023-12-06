# frozen_string_literal: true

require 'thor'

module GoodJob
  #
  # Implements the +good_job+ command-line tool, which executes jobs and
  # provides other utilities. The actual entry point is in +exe/good_job+, but
  # it just sets up and calls this class.
  #
  # The +good_job+ command-line tool is based on Thor, a CLI framework for
  # Ruby. For more on general usage, see http://whatisthor.com/ and
  # https://github.com/erikhuda/thor/wiki.
  #
  class CLI < Thor
    # Path to the local Rails application's environment configuration.
    # Requiring this loads the application's configuration and classes.
    RAILS_ENVIRONMENT_RB = File.expand_path("config/environment.rb")

    # Number of seconds between checking shutdown conditions
    SHUTDOWN_EVENT_TIMEOUT = 10

    class << self
      # Whether the CLI is running from the executable
      # @return [Boolean, nil]
      attr_accessor :within_exe
      alias within_exe? within_exe

      # Whether to log to STDOUT
      # @return [Boolean, nil]
      attr_accessor :log_to_stdout
      alias log_to_stdout? log_to_stdout

      # @!visibility private
      def exit_on_failure?
        true
      end
    end

    # @!macro thor.desc
    #   @!method $1
    #   @return [void]
    #   The +good_job $1+ command. $2
    desc :start, "Executes queued jobs."
    long_desc <<~DESCRIPTION
      Executes queued jobs.

      All options can be configured with environment variables.
      See option descriptions for the matching environment variable name.

      == Configuring queues

      Separate multiple queues with commas; exclude queues with a leading minus;
      separate isolated execution pools with semicolons and threads with colons.

    DESCRIPTION
    method_option :queues,
                  type: :string,
                  banner: "QUEUE_LIST",
                  desc: "Queues or queue pools to work from. (env var: GOOD_JOB_QUEUES, default: *)"
    method_option :max_threads,
                  type: :numeric,
                  banner: 'COUNT',
                  desc: "Default number of threads per pool to use for working jobs. (env var: GOOD_JOB_MAX_THREADS, default: 5)"
    method_option :poll_interval,
                  type: :numeric,
                  banner: 'SECONDS',
                  desc: "Interval between polls for available jobs in seconds (env var: GOOD_JOB_POLL_INTERVAL, default: 5)"
    method_option :max_cache,
                  type: :numeric,
                  banner: 'COUNT',
                  desc: "Maximum number of scheduled jobs to cache in memory (env var: GOOD_JOB_MAX_CACHE, default: 10000)"
    method_option :shutdown_timeout,
                  type: :numeric,
                  banner: 'SECONDS',
                  desc: "Number of seconds to wait for jobs to finish when shutting down before stopping the thread. (env var: GOOD_JOB_SHUTDOWN_TIMEOUT, default: -1 (forever))"
    method_option :enable_cron,
                  type: :boolean,
                  desc: "Whether to run cron process (default: false)"
    method_option :daemonize,
                  type: :boolean,
                  desc: "Run as a background daemon (default: false)"
    method_option :pidfile,
                  type: :string,
                  desc: "Path to write daemonized Process ID (env var: GOOD_JOB_PIDFILE, default: tmp/pids/good_job.pid)"
    method_option :probe_port,
                  type: :numeric,
                  banner: 'PORT',
                  desc: "Port for http health check (env var: GOOD_JOB_PROBE_PORT, default: nil)"
    method_option :queue_select_limit,
                  type: :numeric,
                  banner: 'COUNT',
                  desc: "The number of queued jobs to select when polling for a job to run. (env var: GOOD_JOB_QUEUE_SELECT_LIMIT, default: nil)"

    def start
      set_up_application!
      GoodJob.configuration.options.merge!(options.symbolize_keys)
      configuration = GoodJob.configuration
      capsule = GoodJob.capsule
      systemd = GoodJob::SystemdService.new

      Daemon.new(pidfile: configuration.pidfile).daemonize if configuration.daemonize?

      capsule.start
      systemd.start

      middleware = Rails.application.config.good_job.middleware
      port = Rails.application.config.good_job.middleware_port
      if middleware && port
        probe_server = GoodJob::UtilityServer.new(app: middleware, port: port)
        probe_server.start
      end

      require 'concurrent/atomic/event'
      @stop_good_job_executable = Concurrent::Event.new
      %w[INT TERM].each do |signal|
        trap(signal) { Thread.new { @stop_good_job_executable.set }.join }
      end

      Kernel.loop do
        @stop_good_job_executable.wait(SHUTDOWN_EVENT_TIMEOUT)
        break if @stop_good_job_executable.set? || capsule.shutdown?
      end

      systemd.stop do
        capsule.shutdown(timeout: configuration.shutdown_timeout)
        probe_server&.stop
      end
    end

    default_task :start

    # @!macro thor.desc
    desc :cleanup_preserved_jobs, "Destroys preserved job records."
    long_desc <<~DESCRIPTION
      Manually destroys preserved job records.

      By default, GoodJob automatically destroys job records when the job is performed
      and this command is not required to be used.

    DESCRIPTION
    method_option :before_seconds_ago,
                  type: :numeric,
                  banner: 'SECONDS',
                  desc: "Destroy records finished more than this many seconds ago (env var: GOOD_JOB_CLEANUP_PRESERVED_JOBS_BEFORE_SECONDS_AGO, default: 1209600 (14 days))"

    def cleanup_preserved_jobs
      set_up_application!
      GoodJob.configuration.options.merge!(options.symbolize_keys)

      GoodJob.cleanup_preserved_jobs(older_than: GoodJob.configuration.cleanup_preserved_jobs_before_seconds_ago)
    end

    no_commands do
      # Load the current Rails application and configuration that the good_job
      # command-line tool should be working within.
      #
      # GoodJob components that need access to constants, classes, etc. from
      # Rails or from the application can be set up here.
      def set_up_application!
        require RAILS_ENVIRONMENT_RB
        return unless GoodJob::CLI.log_to_stdout?

        $stdout.sync = true
        return if ActiveSupport::Logger.logger_outputs_to?(GoodJob.logger, $stdout)

        GoodJob::LogSubscriber.loggers << ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new($stdout))
        GoodJob::LogSubscriber.reset_logger
      end
    end
  end
end
