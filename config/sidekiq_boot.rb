# This is an environment file that is to be used when loading the
# Sidekiq Asynch job queue. It loads only what the workers need.

# Start sidekiq manually with:
# bundle exec sidekiq -c 5 -v -r './config/sidekiq_boot.rb

# Heroku note. This will need to be manually started at least once:
# heroku ps:scale worker=1

require 'json'
require 'redis'
require 'redis-namespace'
require 'sidekiq'
require 'sidekiq-scheduler'
require 'tierion'

Dir.glob('./workers/*.rb').each { |file| require file }

redis_uri = URI.parse(ENV['REDIS_URL'] ||= 'redis://127.0.0.1:6379')
$redis = Redis.new(uri: redis_uri)

if $redis.blank?
  raise 'Exiting. The $redis client is nil.'
end

if ENV['TIERION_ENABLED'] && ENV['TIERION_USERNAME'].present? && ENV['TIERION_PASSWORD'].present?
  $blockchain = Tierion::HashApi::Client.new()
end

if ENV['TIERION_ENABLED'] && $blockchain.blank?
  raise 'Exiting. TIERION_ENABLED is true, but $blockchain is nil. Bad auth?'
end

Sidekiq.configure_client do |config|
  config.redis = { namespace: 'sidekiq' }
end

Sidekiq.configure_server do |config|
  config.redis = { namespace: 'sidekiq' }
  config.on(:startup) do
    schedule = YAML.load_file(File.expand_path('../../config/sidekiq_scheduler.yml', __FILE__))
    Sidekiq.schedule = schedule
    Sidekiq::Scheduler.reload_schedule!
  end
end

# Register a callback URL for Tierion (optional)
if ENV['TIERION_ENABLED'] && ENV['RACK_ENV'] == 'production'
  begin
    callback_uri = ENV['TIERION_SUBSCRIPTION_CALLBACK_URI']
    $blockchain.create_block_subscription(callback_uri) if callback_uri.present?
  rescue StandardError
    # no-op : duplicate registration can throw exception
  end
end
