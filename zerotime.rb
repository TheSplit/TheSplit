require 'sinatra'
require 'sinatra/param'
require 'sinatra/cross_origin'
require 'json'
require 'redis'
require 'rbnacl/libsodium'
require 'rbnacl'
require 'blake2'

# http://edgeguides.rubyonrails.org/active_support_core_extensions.html#time
require 'active_support'
require 'active_support/core_ext/object/blank.rb'
require 'active_support/core_ext/numeric'
require 'active_support/core_ext/string/starts_ends_with.rb'
require 'active_support/core_ext/object/try.rb'

helpers Sinatra::Param

SECRETS_EXPIRE_SECS = 30.days

# 2**16
SECRET_MAX_LEN_BYTES = 65_536

BASE64_REGEX = /^[a-zA-Z0-9+=\/\-\_]+$/
HEX_REGEX = /^[a-f0-9]+$/

redis = Redis.new(url: ENV['REDIS_URL'] ||= 'redis://127.0.0.1:6379')

configure do
  # CORS
  enable :cross_origin
  set :server, :puma
  disable :show_exceptions
end

configure :production, :development do
  enable :logging
end

before do
  content_type :json
end

get '/' do
  content_type :html
  erb :index
end

post '/api/v1/secret' do
  param :blake2sHash, String, required: true, min_length: 32, max_length: 32,
                              format: HEX_REGEX

  param :boxNonceB64, String, required: true, min_length: 24, max_length: 64,
                              format: BASE64_REGEX

  param :boxB64, String, required: true, min_length: 1,
                         max_length: SECRET_MAX_LEN_BYTES, format: BASE64_REGEX

  param :scryptSaltB64, String, required: true, min_length: 24, max_length: 64,
                                format: BASE64_REGEX

  blake2s_hash    = params['blake2sHash']
  scrypt_salt_b64 = params['scryptSaltB64']
  box_nonce_b64   = params['boxNonceB64']
  box_b64         = params['boxB64']

  unless valid_hash?(blake2s_hash, [scrypt_salt_b64, box_nonce_b64, box_b64])
    err = {
      message: 'Parameter must contain valid hash of required params',
      errors: {
        blake2sHash: 'Parameter must contain valid hash of required params'
      }
    }
    halt 400, err.to_json
  end

  t = Time.now
  t_exp = t + SECRETS_EXPIRE_SECS

  key = "zerotime:secret:#{blake2s_hash}"
  redis.set(key, { boxNonceB64: box_nonce_b64,
                   boxB64: box_b64,
                   scryptSaltB64: scrypt_salt_b64 }.to_json)

  redis.expire(key, SECRETS_EXPIRE_SECS)

  return { id: blake2s_hash,
           createdAt: t.utc.iso8601,
           expiresAt: t_exp.utc.iso8601 }.to_json
end

get '/api/v1/secret/:id' do
  # id is 16 Byte blake2s hash of the data that was stored
  param :id, String, required: true, min_length: 32, max_length: 32,
                     format: HEX_REGEX

  key = "zerotime:secret:#{params['id']}"
  sec_json = redis.get(key)

  if sec_json.blank?
    logger.warn "GET /api/v1/secret/:id : id not found : #{params['id']}"
    raise Sinatra::NotFound
  end

  begin
    sec = JSON.parse(sec_json)
  rescue StandardError => e
    # bad json from redis!
    logger.error "GET /api/v1/secret/:id : JSON.parse failed : #{e.class} : #{e.message} : #{sec_json}"
    raise Sinatra::NotFound
  ensure
    # Ensure we always delete found data immediately on
    # first view, no matter what happens with the parse.
    redis.del(key)
    logger.info "GET /api/v1/secret/:id : deleted id : #{params['id']}"
  end

  # validate the outgoing data against the hash it was stored under to
  # ensure it has not been modified while at rest.
  unless valid_hash?(params['id'], [sec['scryptSaltB64'], sec['boxNonceB64'], sec['boxB64']])
    err = {
      message: 'Server error, stored data does not match its hash, discarding',
      errors: {
        server: 'Server error, stored data does not match its hash, discarding'
      }
    }
    halt 500, err.to_json
  end

  return { secret: sec }.to_json
end

# sinatra-cross_origin : Handle CORS OPTIONS pre-flight
# requests properly. See: https://github.com/britg/sinatra-cross_origin
options '*' do
  response.headers['Allow'] = 'HEAD,GET,PUT,POST,DELETE,OPTIONS'
  response.headers['Access-Control-Allow-Headers'] = 'X-Requested-With, X-HTTP-Method-Override, Content-Type, Cache-Control, Accept'
  200
end

# Sinatra::NotFound handler
not_found do
  err = {
    message: 'Not found',
    errors: {
      server: 'Not found'
    }
  }
  halt 404, err.to_json
end

# Unhandled error handler
error do
  logger.error "unhandled error : #{err.to_json}"
  err = {
    message: 'Server error',
    errors: {
      server: 'Server error'
    }
  }
  halt 500, err.to_json
end

# Integrity check helper. Ensure the content that will be
# stored, or that has been retrieved, matches exactly
# what was HMAC'ed on the client using BLAKE2s with
# a shared pepper and 16 Byte output.
def valid_hash?(client_hash, server_arr)
  b2_pepper = Blake2::Key.from_string('zerotime')
  server_hash = Blake2.hex(server_arr.join, b2_pepper, 16)
  # secure constant-time string comparison
  if RbNaCl::Util.verify32(server_hash, client_hash)
    return true
  else
    logger.warn "valid_hash? : false : #{client_hash} : #{server_hash}"
    return false
  end
end
