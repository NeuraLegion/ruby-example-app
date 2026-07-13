#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'ostruct'
require 'rack'

ROOT = File.expand_path(__dir__)

def discover_source_path(rel_path)
  direct = File.join(ROOT, rel_path)
  return direct if File.file?(direct)

  pattern = File.join(ROOT, '**', File.basename(rel_path))
  excluded = %w[vendor node_modules tmp log .git coverage pkg .bundle]
  Dir.glob(pattern).find do |path|
    next false unless File.file?(path)

    rel = path.sub(%r{^#{Regexp.escape(ROOT)}/?}, '')
    next false if excluded.any? { |part| rel.split(File::SEPARATOR).include?(part) }

    rel.end_with?(rel_path) || rel.include?(File.basename(rel_path))
  end
end

def safe_require(rel_path)
  path = discover_source_path(rel_path)
  raise LoadError, "not found: #{rel_path}" unless path

  require path
end

def load_active_record_models
  return if defined?(ActiveRecord::Base) && defined?(Post) && defined?(User)

  require 'active_record'
  ActiveRecord::Base.establish_connection(ENV['DATABASE_URL'] || {
    adapter: 'postgresql',
    host: ENV['PGHOST'] || ENV['DATABASE_HOST'] || 'postgres',
    port: (ENV['PGPORT'] || '5432').to_i,
    username: ENV['PGUSER'] || 'postgres',
    password: ENV['PGPASSWORD'] || 'postgres',
    database: ENV['PGDATABASE'] || 'blog_development'
  })

  safe_require('app/models/post.rb')
  safe_require('app/models/user.rb')
end

def load_action_controller_parameters
  return if defined?(ActionController::Parameters)

  require 'action_controller'
end

def load_application_controller
  return if defined?(ApplicationController)

  load_action_controller_parameters unless defined?(ActionController::Base)
  safe_require('app/controllers/application_controller.rb')
end

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
      out[(k.is_a?(String) ? k.to_sym : k)] = symbolize_hash(v)
    end
  when Array
    value.map { |item| symbolize_hash(item) }
  else
    value
  end
end

class HarnessController < ApplicationController
  attr_accessor :session

  def initialize
    super()
    @session = {}
  end

  def redirect_to(target, options = {})
    @harness_redirect = [target, options]
  end

  def harness_redirect
    @harness_redirect
  end
end

TARGETS = {}

begin
  load_active_record_models
  TARGETS['post_where'] = lambda do |req|
    conditions = req.params['conditions'].to_s
    relation = Post.where(conditions)
    count = relation.count
    text(200, "Post.where executed\nconditions=#{conditions}\ncount=#{count}")
  end
rescue StandardError, LoadError => e
  warn("Skipping post_where: #{e.class}: #{e.message}")
end

begin
  load_active_record_models
  TARGETS['user_new'] = lambda do |req|
    payload = parse_body_hash(req)
    attrs = payload['attributes'] || payload[:attributes] || payload
    attrs = symbolize_hash(attrs || {})
    user = User.new(attrs)
    text(200, "User.new executed\nattributes=#{attrs.inspect}\nadmin=#{user.admin.inspect}\npassword_digest=#{user.password_digest.inspect}")
  end
rescue StandardError, LoadError => e
  warn("Skipping user_new: #{e.class}: #{e.message}")
end

begin
  load_active_record_models
  TARGETS['activerecord_persistence_update'] = lambda do |req|
    payload = parse_body_hash(req)
    attrs = payload['attributes'] || payload[:attributes] || payload
    attrs = symbolize_hash(attrs || {})
    user = User.first || User.create!(email: "harness-#{Time.now.to_i}@example.com", password: 'pw')
    user.update(attrs)
    user.reload
    text(200, "update executed\nuser_id=#{user.id}\nadmin=#{user.admin.inspect}\npassword_digest=#{user.password_digest.inspect}")
  end
rescue StandardError, LoadError => e
  warn("Skipping activerecord_persistence_update: #{e.class}: #{e.message}")
end

begin
  load_action_controller_parameters
  TARGETS['actioncontroller_parameters_permit'] = lambda do |req|
    payload = parse_body_hash(req)
    filters = payload['filters'] || payload[:filters] || req.params['filters'] || []
    filters = filters.split(',').map(&:strip) if filters.is_a?(String)
    filters = Array(filters).map { |f| f.to_s.sub(/^:/, '').to_sym }
    input = payload['input'] || payload[:input] || payload['user'] || payload[:user] || { email: 'a@b', password: 'pw', password_digest: 'attacker', admin: true }
    params = ActionController::Parameters.new(user: input)
    permitted = params.require(:user).permit(*filters)
    text(200, "permit executed\nfilters=#{filters.inspect}\npermitted=#{permitted.to_h.inspect}")
  end
rescue StandardError, LoadError => e
  warn("Skipping actioncontroller_parameters_permit: #{e.class}: #{e.message}")
end

begin
  load_application_controller
  TARGETS['applicationcontroller_login_user'] = lambda do |req|
    payload = parse_body_hash(req)
    user_data = payload['user'] || payload[:user] || {}
    user = OpenStruct.new(symbolize_hash(user_data))
    user.define_singleton_method(:persisted?) { !!self[:persisted?] || !!self.persisted } unless user.respond_to?(:persisted?)
    controller = HarnessController.new
    controller.login_user(user)
    text(200, "login_user executed\nsession=#{controller.session.inspect}")
  end
rescue StandardError, LoadError => e
  warn("Skipping applicationcontroller_login_user: #{e.class}: #{e.message}")
end

begin
  load_application_controller
  TARGETS['applicationcontroller_authenticate'] = lambda do |req|
    payload = parse_body_hash(req)
    user_data = payload['user'] || payload[:user] || {}
    password = payload['password'] || payload[:password] || req.params['password']
    user = OpenStruct.new(symbolize_hash(user_data))
    controller = HarnessController.new
    result = controller.authenticate(user, password)
    text(200, "authenticate executed\nresult=#{result.inspect}")
  end
rescue StandardError, LoadError => e
  warn("Skipping applicationcontroller_authenticate: #{e.class}: #{e.message}")
end

begin
  load_application_controller
  TARGETS['applicationcontroller_prevent_login_signup'] = lambda do |req|
    session_user_id = req.params['session[:user_id]'] || req.params['user_id']
    controller = HarnessController.new
    controller.session[:user_id] = session_user_id unless session_user_id.nil? || session_user_id == ''
    controller.prevent_login_signup
    text(200, "prevent_login_signup executed\nredirect=#{controller.harness_redirect.inspect}\nsession=#{controller.session.inspect}")
  end
rescue StandardError, LoadError => e
  warn("Skipping applicationcontroller_prevent_login_signup: #{e.class}: #{e.message}")
end

app = Rack::Builder.new do
  run lambda { |env|
    req = Rack::Request.new(env)

    return text(200, 'ok') if req.get? && req.path == '/health'

    route_map = {
      ['GET', '/harness/post-where'] => TARGETS['post_where'],
      ['POST', '/harness/user-new'] => TARGETS['user_new'],
      ['PUT', '/harness/activerecord--persistence-update'] => TARGETS['activerecord_persistence_update'],
      ['POST', '/harness/actioncontroller--parameters-permit'] => TARGETS['actioncontroller_parameters_permit'],
      ['POST', '/harness/applicationcontroller-login-user'] => TARGETS['applicationcontroller_login_user'],
      ['POST', '/harness/applicationcontroller-authenticate'] => TARGETS['applicationcontroller_authenticate'],
      ['GET', '/harness/applicationcontroller-prevent-login-signup'] => TARGETS['applicationcontroller_prevent_login_signup']
    }

    handler = route_map[[req.request_method, req.path]]
    return text(404, 'not found') unless handler
    return text(503, 'target unavailable') unless handler.respond_to?(:call)

    handler.call(req)
  rescue StandardError => e
    text(500, "#{e.class}: #{e.message}\n#{Array(e.backtrace).first(5).join("\n")}")
  }
end

Rack::Handler::WEBrick.run(app, Host: '0.0.0.0', Port: (ENV['PORT'] || '3001').to_i)
