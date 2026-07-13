#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'ostruct'
require 'rack'

ROOT = File.expand_path(__dir__)
SEARCH_EXCLUDES = %w[vendor node_modules tmp log .git coverage pkg .bundle].freeze

def text(status, body)
  [status, { 'Content-Type' => 'text/plain' }, [body]]
end

def parse_body_hash(req)
  raw = req.body.read.to_s
  req.body.rewind if req.body.respond_to?(:rewind)
  return {} if raw.strip.empty?

  JSON.parse(raw)
rescue JSON::ParserError
  req.POST
end

def symbolize_hash(value)
  case value
  when Hash
    value.each_with_object({}) do |(k, v), out|
      out[k.is_a?(String) ? k.to_sym : k] = symbolize_hash(v)
    end
  when Array
    value.map { |item| symbolize_hash(item) }
  else
    value
  end
end

def discover_project_file(rel_path)
  direct = File.join(ROOT, rel_path)
  return direct if File.file?(direct)

  basename = File.basename(rel_path)
  Dir.glob(File.join(ROOT, '**', basename)).find do |path|
    next false unless File.file?(path)

    relative = path.sub(%r{^#{Regexp.escape(ROOT)}/?}, '')
    parts = relative.split(File::SEPARATOR)
    next false if parts.any? { |part| SEARCH_EXCLUDES.include?(part) }

    relative.end_with?(rel_path)
  end
end

def safe_require_project_file(rel_path)
  path = discover_project_file(rel_path)
  raise LoadError, "Could not locate #{rel_path}" unless path

  require path
  path
end

def ensure_action_controller_parameters
  return if defined?(ActionController::Parameters)

  require 'action_controller'
end

def ensure_application_controller
  return if defined?(ApplicationController)

  ensure_action_controller_parameters unless defined?(ActionController::Base)
  safe_require_project_file('app/controllers/application_controller.rb')
end

class MinimalHarnessController < ApplicationController
  attr_accessor :session
  attr_reader :harness_redirect

  def initialize
    @session = {}
  end

  def redirect_to(target, options = {})
    @harness_redirect = [target, options]
  end
end

def build_user_like_object(input)
  data = symbolize_hash(input || {})
  persisted_flag = if data.key?(:persisted?)
                     data[:persisted?]
                   elsif data.key?(:persisted)
                     data[:persisted]
                   else
                     nil
                   end

  attrs = data.each_with_object({}) do |(key, value), out|
    next if key == :persisted?

    out[key] = value
  end

  user = OpenStruct.new(attrs)
  user.define_singleton_method(:persisted?) { !!persisted_flag }
  user
end

TARGETS = {}

begin
  ensure_action_controller_parameters
  safe_require_project_file('app/controllers/users_controller.rb')
  if defined?(ActionController::Parameters) && ActionController::Parameters.instance_methods.include?(:permit)
    TARGETS[['POST', '/harness/actioncontroller--parameters-permit']] = lambda do |req|
      payload = parse_body_hash(req)
      filters = payload['filters'] || payload[:filters] || req.params['filters'] || []
      filters = filters.split(',') if filters.is_a?(String)
      filters = Array(filters).map { |item| item.to_s.strip.sub(/^:/, '').to_sym }
      user_input = payload['user'] || payload[:user] || {
        email: 'a@example.com',
        password: 'secret',
        password_digest: 'attacker-controlled',
        admin: true
      }
      params = ActionController::Parameters.new(user: user_input)
      permitted = params.require(:user).permit(*filters)
      text(200, "permit executed\nfilters=#{filters.inspect}\npermitted=#{permitted.to_h.inspect}")
    end
  end
rescue StandardError, LoadError => e
  warn("Skipping ActionController::Parameters.permit harness: #{e.class}: #{e.message}")
end

begin
  ensure_application_controller
  if defined?(ApplicationController) && ApplicationController.instance_methods.include?(:login_user)
    TARGETS[['POST', '/harness/applicationcontroller-login-user']] = lambda do |req|
      payload = parse_body_hash(req)
      user = build_user_like_object(payload['user'] || payload[:user] || {
        id: 1,
        password: 'secret',
        persisted: true
      })
      controller = MinimalHarnessController.new
      controller.login_user(user)
      text(200, "login_user executed\nsession=#{controller.session.inspect}")
    end
  end
rescue StandardError, LoadError => e
  warn("Skipping ApplicationController.login_user harness: #{e.class}: #{e.message}")
end

begin
  ensure_application_controller
  if defined?(ApplicationController) && ApplicationController.instance_methods.include?(:authenticate)
    TARGETS[['POST', '/harness/applicationcontroller-authenticate']] = lambda do |req|
      payload = parse_body_hash(req)
      user = build_user_like_object(payload['user'] || payload[:user] || { password: 'secret' })
      password = payload['password'] || payload[:password] || req.params['password'] || 'secret'
      controller = MinimalHarnessController.new
      result = controller.authenticate(user, password)
      text(200, "authenticate executed\nresult=#{result.inspect}")
    end
  end
rescue StandardError, LoadError => e
  warn("Skipping ApplicationController.authenticate harness: #{e.class}: #{e.message}")
end

begin
  ensure_application_controller
  if defined?(ApplicationController) && ApplicationController.instance_methods.include?(:prevent_login_signup)
    TARGETS[['GET', '/harness/applicationcontroller-prevent-login-signup']] = lambda do |req|
      session_user_id = req.params['session[:user_id]'] || req.params['user_id']
      controller = MinimalHarnessController.new
      controller.session[:user_id] = session_user_id unless session_user_id.nil? || session_user_id == ''
      controller.prevent_login_signup
      text(200, "prevent_login_signup executed\nredirect=#{controller.harness_redirect.inspect}\nsession=#{controller.session.inspect}")
    end
  end
rescue StandardError, LoadError => e
  warn("Skipping ApplicationController.prevent_login_signup harness: #{e.class}: #{e.message}")
end

app = lambda do |env|
  req = Rack::Request.new(env)
  return text(200, 'ok') if req.get? && req.path == '/health'

  handler = TARGETS[[req.request_method, req.path]]
  return text(404, 'not found') unless handler

  handler.call(req)
rescue StandardError => e
  text(500, "#{e.class}: #{e.message}\n#{Array(e.backtrace).first(5).join("\n")}")
end

Rack::Handler::WEBrick.run(app, Host: '0.0.0.0', Port: (ENV['PORT'] || '3001').to_i)
