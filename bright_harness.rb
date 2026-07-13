begin
  require 'bundler/setup'
rescue LoadError
end

require 'json'
require 'yaml'
require 'ostruct'
require 'rack'

ROOT = File.expand_path(__dir__)

module BrightHarness
  module_function

  IGNORE_FRAGMENTS = %w[/vendor/ /tmp/ /.git/ /node_modules/ /log/ /coverage/].freeze

  def repo_file(path)
    direct = File.expand_path(path, ROOT)
    return direct if File.file?(direct)

    basename = File.basename(path)
    matches = Dir.glob(File.join(ROOT, '**', basename)).reject do |entry|
      IGNORE_FRAGMENTS.any? { |fragment| entry.include?(fragment) }
    end
    matches.find { |entry| entry.end_with?(path) } || matches.first
  end

  def ensure_action_controller_stub
    return if defined?(ActionController::Base)

    action_controller = Module.new
    base = Class.new do
      def self.helper_method(*) end
    end

    action_controller.const_set(:Base, base)
    Object.const_set(:ActionController, action_controller)
  end

  def load_target(path)
    ensure_action_controller_stub
    file = repo_file(path)
    raise LoadError, "target not found: #{path}" unless file

    load file
    file
  end

  def parse_body(req)
    raw = req.body.read.to_s
    req.body.rewind if req.body.respond_to?(:rewind)
    return {} if raw.strip.empty?

    begin
      parsed = JSON.parse(raw)
      return parsed if parsed.is_a?(Hash)
    rescue JSON::ParserError
    end

    begin
      parsed = YAML.respond_to?(:unsafe_load) ? YAML.unsafe_load(raw) : YAML.load(raw)
      return parsed if parsed.is_a?(Hash)
    rescue StandardError
    end

    {}
  end

  def request_params(req)
    req.params.merge(parse_body(req))
  end

  def text(status, body)
    [status, { 'Content-Type' => 'text/plain' }, [body]]
  end
end

targets = {}

begin
  BrightHarness.load_target('app/controllers/application_controller.rb')
  if defined?(ApplicationController) && ApplicationController.instance_methods.include?(:authenticate)
    targets[['POST', '/harness/applicationcontroller-authenticate']] = proc do |req|
      params = BrightHarness.request_params(req)
      user_param = params['user'] || params[:user]
      password = params['password'] || params[:password]

      user = case user_param
      when OpenStruct
        user_param
      when Hash
        OpenStruct.new(password: user_param['password'] || user_param[:password])
      else
        OpenStruct.new(password: user_param.to_s)
      end

      result = ApplicationController.new.authenticate(user, password)
      BrightHarness.text(200, result.inspect)
    end
  end
rescue StandardError, LoadError => e
  warn("Skipping ApplicationController target: #{e.class}: #{e.message}")
end

app = proc do |env|
  req = Rack::Request.new(env)
  return BrightHarness.text(200, 'ok') if req.get? && req.path == '/health'

  handler = targets[[req.request_method, req.path]]
  return BrightHarness.text(404, 'not found') unless handler

  begin
    handler.call(req)
  rescue StandardError => e
    BrightHarness.text(500, "#{e.class}: #{e.message}")
  end
end

Rack::Handler::WEBrick.run(app, Host: '0.0.0.0', Port: (ENV['PORT'] || '3001').to_i)
