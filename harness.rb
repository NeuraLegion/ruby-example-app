#!/usr/bin/env ruby

ROOT = File.expand_path(__dir__)

ENV['BUNDLE_GEMFILE'] ||= File.expand_path('Gemfile', ROOT)

require 'bundler/setup'
require 'rack'
require 'json'
require 'ostruct'
require 'action_controller'
require 'action_dispatch'
require 'webrick'

def plain(status, body)
  [status, { 'Content-Type' => 'text/plain' }, [body.to_s]]
end

def excluded_path?(path)
  path.include?('/vendor/') ||
    path.include?('/node_modules/') ||
    path.include?('/tmp/') ||
    path.include?('/log/') ||
    path.include?('/.bundle/') ||
    path.include?('/bundle/')
end

def discover_source_path(preferred)
  direct = File.expand_path(preferred, ROOT)
  return direct if File.file?(direct)

  basename = File.basename(preferred)
  Dir.glob(File.join(ROOT, '**', basename)).sort.each do |candidate|
    next unless File.file?(candidate)
    next if excluded_path?(candidate)
    return candidate if candidate.end_with?(preferred)
  end

  nil
end

def load_target(relative_path)
  path = discover_source_path(relative_path)
  return [false, "missing file #{relative_path}"] unless path

  load path
  [true, nil]
rescue LoadError, StandardError => e
  [false, "#{e.class}: #{e.message}"]
end

unless defined?(ActionController::Base)
  abort('action_controller unavailable')
end

unless defined?(ApplicationController)
  class ApplicationController < ActionController::Base
  end
end

LOAD_RESULTS = {}

[
  'app/controllers/application_controller.rb',
  'app/controllers/users_controller.rb',
  'app/controllers/posts_controller.rb'
].each do |target|
  LOAD_RESULTS[target] = load_target(target)
  warn("[harness] skipped #{target}: #{LOAD_RESULTS[target][1]}") unless LOAD_RESULTS[target][0]
end

module HarnessSupport
  def harness_initialize(params_hash: {}, session_hash: {}, referer: nil)
    @_harness_params = ActionController::Parameters.new(params_hash)
    @_harness_session = session_hash
    @_harness_request = OpenStruct.new(referer: referer)
    @_harness_redirect = nil
  end

  def params
    @_harness_params
  end

  def session
    @_harness_session
  end

  def request
    @_harness_request
  end

  def redirect_to(target, *_args)
    @_harness_redirect = (target == :back ? request.referer : target)
  end

  def harness_redirect
    @_harness_redirect
  end

  def serialize(value)
    case value
    when ActionController::Parameters
      value.to_unsafe_h.inspect
    else
      value.inspect
    end
  end
end

def build_controller(klass, params_hash: {}, session_hash: {}, referer: nil)
  controller = klass.allocate
  controller.extend(HarnessSupport)
  controller.harness_initialize(params_hash: params_hash, session_hash: session_hash, referer: referer)
  controller
end

def normalize_bool(value)
  case value
  when true, 'true', '1', 1, 'yes', 'on' then true
  else false
  end
end

def extract_nested_hash(req, root_key)
  direct = req.params[root_key]
  return direct if direct.is_a?(Hash)

  nested = {}
  prefix = "#{root_key}["
  req.params.each do |key, value|
    next unless key.start_with?(prefix) && key.end_with?(']')
    nested[key[prefix.length..-2]] = value
  end
  nested
end

routes = {}

if LOAD_RESULTS['app/controllers/users_controller.rb'][0] && defined?(UsersController)
  routes['/harness/userscontroller-user-params'] = proc do |req|
    begin
      user_hash = extract_nested_hash(req, 'user')
      payload = {
        user: {
          email: user_hash['email'],
          password: user_hash['password'],
          password_digest: user_hash['password_digest'],
          admin: user_hash.key?('admin') ? normalize_bool(user_hash['admin']) : user_hash['admin']
        }
      }
      controller = build_controller(UsersController, params_hash: payload)
      result = controller.send(:user_params)
      plain(200, controller.serialize(result))
    rescue StandardError => e
      plain(500, "#{e.class}: #{e.message}")
    end
  end
end

if LOAD_RESULTS['app/controllers/posts_controller.rb'][0] && defined?(PostsController)
  routes['/harness/postscontroller-post-params'] = proc do |req|
    begin
      post_hash = extract_nested_hash(req, 'post')
      payload = {
        post: {
          title: post_hash['title'],
          content: post_hash['content'],
          public: post_hash.key?('public') ? normalize_bool(post_hash['public']) : post_hash['public']
        }
      }
      controller = build_controller(PostsController, params_hash: payload)
      result = controller.send(:post_params)
      plain(200, controller.serialize(result))
    rescue StandardError => e
      plain(500, "#{e.class}: #{e.message}")
    end
  end
end

if LOAD_RESULTS['app/controllers/application_controller.rb'][0] && defined?(ApplicationController)
  routes['/harness/applicationcontroller-login-user'] = proc do |req|
    begin
      controller = build_controller(ApplicationController, session_hash: {})
      user = OpenStruct.new(
        id: (req.params['user_id'] || req.params['user[id]'] || 1).to_i,
        password: req.params['password'] || req.params['user[password]'] || 'secret',
        persisted?: true
      )
      controller.login_user(user)
      plain(200, controller.session.inspect)
    rescue StandardError => e
      plain(500, "#{e.class}: #{e.message}")
    end
  end

  routes['/harness/applicationcontroller-prevent-login-signup'] = proc do |req|
    begin
      session_value = req.params['session[:user_id]'] || req.params['user_id']
      referer = req.params['request referer'] || req.params['referer']
      controller = build_controller(
        ApplicationController,
        session_hash: { user_id: session_value.nil? || session_value == '' ? nil : session_value.to_i },
        referer: referer
      )
      controller.prevent_login_signup
      plain(200, "redirect=#{controller.harness_redirect.inspect}\nsession=#{controller.session.inspect}")
    rescue StandardError => e
      plain(500, "#{e.class}: #{e.message}")
    end
  end
end

app = proc do |env|
  req = Rack::Request.new(env)
  if req.path_info == '/health'
    plain(200, 'ok')
  else
    handler = routes[req.path_info]
    unless handler
      plain(404, 'not found')
    else
      expected_method = case req.path_info
                        when '/harness/applicationcontroller-prevent-login-signup' then 'GET'
                        else 'POST'
                        end

      if req.request_method == expected_method
        handler.call(req)
      else
        plain(405, 'method not allowed')
      end
    end
  end
end

Rack::Handler::WEBrick.run(
  app,
  Host: '0.0.0.0',
  Port: (ENV['PORT'] || '3001').to_i,
  AccessLog: [],
  Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN)
)
