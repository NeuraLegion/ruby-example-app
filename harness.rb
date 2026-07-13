begin
  require 'bundler/setup'
rescue LoadError
end

require 'json'
require 'yaml'
require 'pathname'
require 'rack'

ROOT = File.expand_path(__dir__)

ENV['DATABASE_URL'] ||= 'postgres://postgres:postgres@postgres:5432/blog_development'
ENV['BLOG_DATABASE_PASSWORD'] ||= '<set in production>'

module Harness
  module_function

  def repo_file(path)
    candidate = File.expand_path(path, ROOT)
    return candidate if File.file?(candidate)

    basename = File.basename(path)
    ignored = %w[/vendor/ /tmp/ /.git/ /node_modules/ /log/]
    matches = Dir.glob(File.join(ROOT, '**', basename)).reject do |entry|
      ignored.any? { |fragment| entry.include?(fragment) }
    end
    matches.find { |entry| entry.end_with?(path) } || matches.first
  end

  def setup_activerecord
    return if defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?

    require 'active_record'
    require 'erb'

    db_yml = repo_file('config/database.yml')
    config = if db_yml && File.file?(db_yml)
      raw = ERB.new(File.read(db_yml)).result
      YAML.respond_to?(:unsafe_load) ? YAML.unsafe_load(raw) : YAML.load(raw)
    else
      {}
    end

    env_name = ENV['RAILS_ENV'] || ENV['RACK_ENV'] || 'development'
    chosen = (config && config[env_name]) || {}
    chosen = chosen.dup
    chosen['url'] ||= ENV['DATABASE_URL'] if ENV['DATABASE_URL'] && !ENV['DATABASE_URL'].empty?
    chosen['host'] ||= ENV['PGHOST'] if ENV['PGHOST']
    chosen['port'] ||= ENV['PGPORT'] if ENV['PGPORT']
    chosen['username'] ||= ENV['PGUSER'] if ENV['PGUSER']
    chosen['password'] ||= ENV['PGPASSWORD'] if ENV['PGPASSWORD']
    chosen['database'] ||= ENV['PGDATABASE'] if ENV['PGDATABASE']

    ActiveRecord::Base.establish_connection(chosen)
  end

  def ensure_action_controller_stub
    return if defined?(ActionController::Base)

    module ::ActionController
      class Base
        def self.helper_method(*) end
      end
    end
  end

  def load_target(path, kind: nil)
    setup_activerecord if kind == :db
    ensure_action_controller_stub if kind == :controller
    file = repo_file(path)
    raise LoadError, "target not found: #{path}" unless file

    load file
    file
  end

  def parse_value(raw)
    return nil if raw.nil?

    begin
      JSON.parse(raw)
    rescue JSON::ParserError
      begin
        YAML.respond_to?(:unsafe_load) ? YAML.unsafe_load(raw) : YAML.load(raw)
      rescue StandardError
        raw
      end
    end
  end

  def request_params(req)
    params = {}
    req.params.each { |k, v| params[k] = v }

    if req.post? || req.put? || req.patch?
      body = req.body.read.to_s
      req.body.rewind if req.body.respond_to?(:rewind)
      unless body.strip.empty?
        parsed = parse_value(body)
        params.merge!(parsed) if parsed.is_a?(Hash)
      end
    end

    params
  end

  def text(status, body)
    [status, { 'Content-Type' => 'text/plain' }, [body]]
  end
end

TARGETS = {}

begin
  Harness.load_target('app/models/post.rb', kind: :db)
  if defined?(Post)
    TARGETS[['GET', '/harness/post-where']] = proc do |req|
      conditions = Harness.request_params(req)['conditions']
      result = Post.where(Harness.parse_value(conditions) || conditions)
      Harness.text(200, result.to_a.inspect)
    end

    TARGETS[['GET', '/harness/post-find']] = proc do |req|
      id = Harness.request_params(req)['id']
      result = Post.find(Harness.parse_value(id) || id)
      Harness.text(200, result.inspect)
    end

    TARGETS[['POST', '/harness/post-new']] = proc do |req|
      attrs = Harness.request_params(req)['attributes']
      result = Post.new(Harness.parse_value(attrs) || attrs || {})
      Harness.text(200, result.attributes.inspect)
    end

    TARGETS[['PUT', '/harness/post-update']] = proc do |req|
      params = Harness.request_params(req)
      attrs = Harness.parse_value(params['attributes']) || params['attributes'] || {}
      id = Harness.parse_value(params['id'] || '1') || params['id'] || 1
      record = Post.find(id)
      result = record.update(attrs)
      Harness.text(200, "updated=#{result.inspect} attributes=#{record.attributes.inspect}")
    end
  end
rescue StandardError => e
  warn("Skipping Post targets: #{e.class}: #{e.message}")
end

begin
  Harness.load_target('app/models/user.rb', kind: :db)
  if defined?(User)
    TARGETS[['GET', '/harness/user-find-by']] = proc do |req|
      attributes = Harness.request_params(req)['attributes']
      result = User.find_by(Harness.parse_value(attributes) || attributes || {})
      Harness.text(200, result.inspect)
    end

    TARGETS[['POST', '/harness/user-where']] = proc do |req|
      attributes = Harness.request_params(req)['attributes']
      result = User.where(Harness.parse_value(attributes) || attributes || {})
      Harness.text(200, result.to_a.inspect)
    end

    TARGETS[['POST', '/harness/user-new']] = proc do |req|
      attributes = Harness.request_params(req)['attributes']
      result = User.new(Harness.parse_value(attributes) || attributes || {})
      Harness.text(200, result.attributes.inspect)
    end

    TARGETS[['PUT', '/harness/user-update']] = proc do |req|
      params = Harness.request_params(req)
      attrs = Harness.parse_value(params['attributes']) || params['attributes'] || {}
      id = Harness.parse_value(params['id'] || '1') || params['id'] || 1
      record = User.find(id)
      result = record.update(attrs)
      Harness.text(200, "updated=#{result.inspect} attributes=#{record.attributes.inspect}")
    end
  end
rescue StandardError => e
  warn("Skipping User targets: #{e.class}: #{e.message}")
end

begin
  Harness.load_target('app/controllers/application_controller.rb', kind: :controller)
  if defined?(ApplicationController)
    TARGETS[['POST', '/harness/applicationcontroller-authenticate']] = proc do |req|
      params = Harness.request_params(req)
      user_data = Harness.parse_value(params['user']) || {}
      password = Harness.parse_value(params['password']) || params['password']
      user = if user_data.respond_to?(:password)
        user_data
      else
        Struct.new(:password).new(user_data.is_a?(Hash) ? (user_data['password'] || user_data[:password]) : user_data.to_s)
      end
      result = ApplicationController.new.authenticate(user, password)
      Harness.text(200, result.inspect)
    end
  end
rescue StandardError => e
  warn("Skipping ApplicationController target: #{e.class}: #{e.message}")
end

app = proc do |env|
  req = Rack::Request.new(env)
  return Harness.text(200, 'ok') if req.get? && req.path == '/health'

  handler = TARGETS[[req.request_method, req.path]]
  begin
    handler ? handler.call(req) : Harness.text(404, 'not found')
  rescue StandardError => e
    Harness.text(500, "#{e.class}: #{e.message}")
  end
end

Rack::Handler::WEBrick.run(app, Host: '0.0.0.0', Port: (ENV['PORT'] || '3001').to_i)
