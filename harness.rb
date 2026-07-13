#!/usr/bin/env ruby
# frozen_string_literal: true

require 'webrick'
require 'json'
require 'cgi'
require 'yaml'
require 'pathname'
require 'rbconfig'
require 'erb'
require 'socket'

ROOT = File.expand_path(__dir__)
APP_DIR = '/app'

module Harness
  module_function

  def text(res, status, body)
    res.status = status
    res['Content-Type'] = 'text/plain'
    res.body = body.to_s
  end

  def parse_bool(value)
    case value.to_s.strip.downcase
    when 'true', '1', 'yes', 'y', 'on' then true
    when 'false', '0', 'no', 'n', 'off' then false
    else nil
    end
  end

  def request_params(req)
    params = {}
    req.query.each { |k, v| params[k] = v }

    if ['POST', 'PUT', 'PATCH'].include?(req.request_method)
      ct = req['content-type'].to_s
      body = req.body.to_s
      if ct.include?('application/json') && !body.empty?
        begin
          parsed = JSON.parse(body)
          if parsed.is_a?(Hash)
            parsed.each { |k, v| params[k.to_s] = v }
          end
        rescue JSON::ParserError
        end
      end
    end

    params
  end

  def excluded_path?(path)
    parts = path.split(File::SEPARATOR)
    parts.include?('vendor') || parts.include?('tmp') || parts.include?('log') ||
      parts.include?('.bundle') || parts.include?('node_modules') ||
      parts.include?('coverage') || parts.include?('.git')
  end

  def resolve_source_path(relative_path)
    candidates = []
    [ROOT, APP_DIR].uniq.each do |base|
      next unless base && Dir.exist?(base)
      direct = File.expand_path(relative_path, base)
      candidates << direct if File.file?(direct)
    end
    return candidates.first unless candidates.empty?

    basename = File.basename(relative_path)
    [ROOT, APP_DIR].uniq.each do |base|
      next unless base && Dir.exist?(base)
      found = Dir.glob(File.join(base, '**', basename)).find do |p|
        File.file?(p) && !excluded_path?(p)
      end
      return found if found
    end
    nil
  end

  def loadable_file(relative_path)
    resolve_source_path(relative_path)
  end

  def app_root
    @app_root ||= begin
      if File.file?(File.join(ROOT, 'Gemfile'))
        ROOT
      elsif File.file?(File.join(APP_DIR, 'Gemfile'))
        APP_DIR
      else
        ROOT
      end
    end
  end

  def resolvable_host?(host)
    return true if host.nil? || host.to_s.strip.empty?
    Socket.getaddrinfo(host, nil)
    true
  rescue SocketError
    false
  end

  def default_sqlite_config
    db_dir = File.join(app_root, 'tmp')
    Dir.mkdir(db_dir) unless Dir.exist?(db_dir)
    {
      'adapter' => 'sqlite3',
      'database' => File.join(db_dir, 'harness.sqlite3')
    }
  end

  def build_connection_config
    db_url = ENV['DATABASE_URL']
    return db_url if db_url && !db_url.empty?

    db_yml = File.join(app_root, 'config', 'database.yml')
    raise "database config not found: #{db_yml}" unless File.file?(db_yml)

    raw = ERB.new(File.read(db_yml)).result
    cfg = YAML.safe_load(raw, aliases: true)
    env_name = ENV['RAILS_ENV'] || ENV['RACK_ENV'] || 'development'
    conf = cfg[env_name] || cfg['development']
    raise "database config missing for #{env_name}" unless conf

    conf = conf.merge('host' => ENV['PGHOST']) if ENV['PGHOST'] && !ENV['PGHOST'].empty?
    conf = conf.merge('port' => ENV['PGPORT']) if ENV['PGPORT'] && !ENV['PGPORT'].empty?
    conf = conf.merge('username' => ENV['PGUSER']) if ENV['PGUSER'] && !ENV['PGUSER'].empty?
    conf = conf.merge('password' => ENV['PGPASSWORD']) if ENV['PGPASSWORD'] && !ENV['PGPASSWORD'].empty?
    conf = conf.merge('database' => ENV['PGDATABASE']) if ENV['PGDATABASE'] && !ENV['PGDATABASE'].empty?

    if conf['adapter'].to_s == 'postgresql' && !resolvable_host?(conf['host'])
      return default_sqlite_config
    end

    conf
  end

  def setup_active_record
    return if defined?(@ar_setup) && @ar_setup

    require 'active_record'
    require 'sqlite3' if build_connection_config.is_a?(Hash) && build_connection_config['adapter'] == 'sqlite3'

    ActiveRecord::Base.establish_connection(build_connection_config)
    ActiveRecord::Base.logger = nil
    @ar_setup = true
  end

  def load_model(relative_path, const_name)
    setup_active_record
    return true if Object.const_defined?(const_name)

    path = loadable_file(relative_path)
    raise LoadError, "could not find #{relative_path}" unless path

    require path
    Object.const_defined?(const_name)
  end

  def ensure_schema
    return if defined?(@schema_ready) && @schema_ready

    setup_active_record
    conn = ActiveRecord::Base.connection
    return if conn.table_exists?(:users) && conn.table_exists?(:posts)

    ActiveRecord::Schema.define do
      suppress_messages do
        create_table :users, force: true do |t|
          t.text :email
          t.text :password
          t.text :password_digest
          t.datetime :created_at, null: false
          t.datetime :updated_at, null: false
          t.boolean :admin, default: false
        end unless conn.table_exists?(:users)

        create_table :posts, force: true do |t|
          t.text :title
          t.text :content
          t.datetime :created_at, null: false
          t.datetime :updated_at, null: false
          t.integer :user_id
          t.boolean :public, default: false
        end unless conn.table_exists?(:posts)

        add_index :posts, :user_id unless conn.index_exists?(:posts, :user_id)
      end
    end

    @schema_ready = true
  end

  def ensure_seed_data
    ensure_schema
    return if defined?(@seeded) && @seeded
    return unless Object.const_defined?('User') && Object.const_defined?('Post')

    begin
      if User.count == 0
        admin = User.create!(email: 'admin@example.com', password: 'pw', password_digest: 'seed_digest', admin: true)
        user = User.create!(email: 'user@example.com', password: 'pw', password_digest: 'seed_digest', admin: false)
        Post.create!(title: 'public post', content: 'foo public content', user_id: user.id, public: true)
        Post.create!(title: 'private post', content: 'foo private content', user_id: admin.id, public: false)
      elsif Post.count == 0
        owner = User.first || User.create!(email: 'seed@example.com', password: 'pw', password_digest: 'seed_digest', admin: false)
        Post.create!(title: 'public post', content: 'foo public content', user_id: owner.id, public: true)
      end
    rescue StandardError
    end

    @seeded = true
  end

  def target_status(name, route, method, loaded, detail = nil)
    { name: name, route: route, method: method, loaded: loaded, detail: detail }
  end
end

TARGETS = []

begin
  if Harness.load_model('app/models/post.rb', 'Post')
    Harness.load_model('app/models/user.rb', 'User') unless Object.const_defined?('User')
    Harness.ensure_seed_data
    TARGETS << Harness.target_status('Post.where(sql_fragment)', '/harness/post-where', 'GET', true, 'model loaded')
    TARGETS << Harness.target_status('Post.find(id)', '/harness/post-find', 'GET', true, 'model loaded')
    TARGETS << Harness.target_status('ActiveRecord::Relation.find_by(id)', '/harness/activerecord--relation-find-by', 'GET', true, 'model loaded')
  else
    TARGETS << Harness.target_status('Post.where(sql_fragment)', '/harness/post-where', 'GET', false, 'Post constant unavailable')
    TARGETS << Harness.target_status('Post.find(id)', '/harness/post-find', 'GET', false, 'Post constant unavailable')
    TARGETS << Harness.target_status('ActiveRecord::Relation.find_by(id)', '/harness/activerecord--relation-find-by', 'GET', false, 'Post constant unavailable')
  end
rescue StandardError => e
  detail = e.class.to_s + ': ' + e.message
  TARGETS << Harness.target_status('Post.where(sql_fragment)', '/harness/post-where', 'GET', false, detail)
  TARGETS << Harness.target_status('Post.find(id)', '/harness/post-find', 'GET', false, detail)
  TARGETS << Harness.target_status('ActiveRecord::Relation.find_by(id)', '/harness/activerecord--relation-find-by', 'GET', false, detail)
end

begin
  if Harness.load_model('app/models/user.rb', 'User')
    Harness.load_model('app/models/post.rb', 'Post') unless Object.const_defined?('Post')
    Harness.ensure_seed_data
    TARGETS << Harness.target_status('User.find_by(id)', '/harness/user-find-by', 'GET', true, 'model loaded')
    TARGETS << Harness.target_status('User.where(email)', '/harness/user-where', 'POST', true, 'model loaded')
    TARGETS << Harness.target_status('User.new(...)', '/harness/user-new', 'POST', true, 'model loaded')
    TARGETS << Harness.target_status('User.update(...)', '/harness/user-update', 'PUT', true, 'model loaded')
  else
    TARGETS << Harness.target_status('User.find_by(id)', '/harness/user-find-by', 'GET', false, 'User constant unavailable')
    TARGETS << Harness.target_status('User.where(email)', '/harness/user-where', 'POST', false, 'User constant unavailable')
    TARGETS << Harness.target_status('User.new(...)', '/harness/user-new', 'POST', false, 'User constant unavailable')
    TARGETS << Harness.target_status('User.update(...)', '/harness/user-update', 'PUT', false, 'User constant unavailable')
  end
rescue StandardError => e
  detail = e.class.to_s + ': ' + e.message
  TARGETS << Harness.target_status('User.find_by(id)', '/harness/user-find-by', 'GET', false, detail)
  TARGETS << Harness.target_status('User.where(email)', '/harness/user-where', 'POST', false, detail)
  TARGETS << Harness.target_status('User.new(...)', '/harness/user-new', 'POST', false, detail)
  TARGETS << Harness.target_status('User.update(...)', '/harness/user-update', 'PUT', false, detail)
end

server = WEBrick::HTTPServer.new(
  Port: (ENV['PORT'] || '3001').to_i,
  BindAddress: '0.0.0.0',
  AccessLog: [],
  Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN)
)

server.mount_proc '/health' do |_req, res|
  loaded = TARGETS.select { |t| t[:loaded] }.count
  Harness.text(res, 200, "ok loaded_targets=#{loaded}/#{TARGETS.count}")
end

server.mount_proc '/harness/post-where' do |req, res|
  unless req.request_method == 'GET'
    Harness.text(res, 405, 'method not allowed')
    next
  end
  unless Object.const_defined?('Post')
    Harness.text(res, 503, 'Post model unavailable')
    next
  end

  params = Harness.request_params(req)
  begin
    if params.key?('sql_fragment')
      relation = Post.where(params['sql_fragment'])
      ids = relation.limit(10).pluck(:id) rescue []
      Harness.text(res, 200, "Post.where(sql_fragment) ok count=#{relation.count} ids=#{ids.join(',')}")
    elsif params.key?('id') || params.key?('public')
      rel = Post.where(id: params['id']).where(public: Harness.parse_bool(params['public']))
      record = rel.first
      Harness.text(res, 200, "Post.where(id, public) ok found=#{record ? 'true' : 'false'} id=#{record && record.id}")
    else
      Harness.text(res, 400, 'missing sql_fragment or id/public params')
    end
  rescue StandardError => e
    Harness.text(res, 500, "#{e.class}: #{e.message}")
  end
end

server.mount_proc '/harness/user-find-by' do |req, res|
  unless req.request_method == 'GET'
    Harness.text(res, 405, 'method not allowed')
    next
  end
  unless Object.const_defined?('User')
    Harness.text(res, 503, 'User model unavailable')
    next
  end

  params = Harness.request_params(req)
  begin
    user = User.find_by(id: params['id'])
    Harness.text(res, 200, "User.find_by(id) ok found=#{user ? 'true' : 'false'} id=#{user && user.id}")
  rescue StandardError => e
    Harness.text(res, 500, "#{e.class}: #{e.message}")
  end
end

server.mount_proc '/harness/post-find' do |req, res|
  unless req.request_method == 'GET'
    Harness.text(res, 405, 'method not allowed')
    next
  end
  unless Object.const_defined?('Post')
    Harness.text(res, 503, 'Post model unavailable')
    next
  end

  params = Harness.request_params(req)
  begin
    post = Post.find(params['id'])
    Harness.text(res, 200, "Post.find(id) ok id=#{post.id}")
  rescue StandardError => e
    Harness.text(res, 500, "#{e.class}: #{e.message}")
  end
end

server.mount_proc '/harness/activerecord--relation-find-by' do |req, res|
  unless req.request_method == 'GET'
    Harness.text(res, 405, 'method not allowed')
    next
  end
  unless Object.const_defined?('User') && Object.const_defined?('Post')
    Harness.text(res, 503, 'User/Post model unavailable')
    next
  end

  params = Harness.request_params(req)
  begin
    owner = User.first || User.create!(email: 'owner@example.com', password: 'pw', password_digest: 'seed_digest', admin: false)
    relation = owner.posts
    post = relation.find_by(id: params['id'])
    Harness.text(res, 200, "ActiveRecord::Relation.find_by(id) ok found=#{post ? 'true' : 'false'} id=#{post && post.id}")
  rescue StandardError => e
    Harness.text(res, 500, "#{e.class}: #{e.message}")
  end
end

server.mount_proc '/harness/user-where' do |req, res|
  unless req.request_method == 'POST'
    Harness.text(res, 405, 'method not allowed')
    next
  end
  unless Object.const_defined?('User')
    Harness.text(res, 503, 'User model unavailable')
    next
  end

  params = Harness.request_params(req)
  begin
    relation = User.where(email: params['email'])
    user = relation.first
    Harness.text(res, 200, "User.where(email) ok found=#{user ? 'true' : 'false'} id=#{user && user.id}")
  rescue StandardError => e
    Harness.text(res, 500, "#{e.class}: #{e.message}")
  end
end

server.mount_proc '/harness/user-new' do |req, res|
  unless req.request_method == 'POST'
    Harness.text(res, 405, 'method not allowed')
    next
  end
  unless Object.const_defined?('User')
    Harness.text(res, 503, 'User model unavailable')
    next
  end

  params = Harness.request_params(req)
  attrs = {
    email: params['email'],
    password: params['password'],
    password_digest: params['password_digest'],
    admin: Harness.parse_bool(params['admin'])
  }

  begin
    user = User.new(attrs)
    Harness.text(res, 200, "User.new ok admin=#{user.admin.inspect} password_digest=#{user.password_digest.inspect} valid=#{user.valid?}")
  rescue StandardError => e
    Harness.text(res, 500, "#{e.class}: #{e.message}")
  end
end

user_update_handler = proc do |req, res|
  unless ['PUT', 'PATCH', 'POST'].include?(req.request_method)
    Harness.text(res, 405, 'method not allowed')
    next
  end
  unless Object.const_defined?('User')
    Harness.text(res, 503, 'User model unavailable')
    next
  end

  params = Harness.request_params(req)
  attrs = {
    email: params['email'],
    password: params['password'],
    password_digest: params['password_digest'],
    admin: Harness.parse_bool(params['admin'])
  }

  begin
    user = User.first || User.create!(email: 'update-seed@example.com', password: 'pw', password_digest: 'seed_digest', admin: false)
    ok = user.update(attrs)
    user.reload
    Harness.text(res, 200, "User.update ok success=#{ok} admin=#{user.admin.inspect} password_digest=#{user.password_digest.inspect} email=#{user.email.inspect}")
  rescue StandardError => e
    Harness.text(res, 500, "#{e.class}: #{e.message}")
  end
end

server.mount_proc '/harness/user-update' do |req, res|
  user_update_handler.call(req, res)
end
server.mount_proc '/harness/user-update/' do |req, res|
  user_update_handler.call(req, res)
end

trap('INT') { server.shutdown }
trap('TERM') { server.shutdown }

server.start
