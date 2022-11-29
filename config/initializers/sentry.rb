Sentry.init do |config|
  #config.dsn = 'set via environment variable'
  config.breadcrumbs_logger = [:monotonic_active_support_logger, :http_logger]
end
