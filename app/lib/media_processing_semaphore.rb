# frozen_string_literal: true

require 'concurrent'

class MediaProcessingSemaphore
  METRIC_PREFIX = 'media_processing.semaphore'

  class << self
    include ::NSA::Statsd::Publisher

    def acquire(&block)
      return yield if skip?

      acquired = semaphore.try_acquire(1, timeout)

      unless acquired
        statsd_increment("#{METRIC_PREFIX}.timeout")
        raise Mastodon::MediaProcessingTimeoutError,
              'Server is busy processing media, please try again'
      end

      statsd_increment("#{METRIC_PREFIX}.success")

      begin
        statsd_time("#{METRIC_PREFIX}.duration") { yield }
      ensure
        semaphore.release
      end
    end

    private

    def semaphore
      # Lazy init ensures this is created AFTER Puma forks workers
      # (preload_app! loads code before fork, but this runs after)
      @semaphore ||= Concurrent::Semaphore.new(permits)
    end

    def permits
      ENV.fetch('MEDIA_PROCESSING_CONCURRENCY', 2).to_i
    end

    def timeout
      ENV.fetch('MEDIA_PROCESSING_TIMEOUT', 10).to_i
    end

    def skip?
      # Disable: set permits to 0
      # Skip in Sidekiq: it has its own concurrency controls
      permits <= 0 || (defined?(Sidekiq::CLI) && Sidekiq.server?)
    end
  end
end
