require 'uri'
require 'cgi'
require 'net/http'
require 'net/https'
require 'json'

module InfluxDB
  class Client
    attr_accessor :hosts,
                  :port,
                  :username,
                  :password,
                  :database,
                  :time_precision,
                  :use_ssl,
                  :stopped

    attr_accessor :queue, :worker

    include InfluxDB::Logging

    # Initializes a new InfluxDB client
    #
    # === Examples:
    #
    #     InfluxDB::Client.new                               # connect to localhost using root/root
    #                                                        # as the credentials and doesn't connect to a db
    #
    #     InfluxDB::Client.new 'db'                          # connect to localhost using root/root
    #                                                        # as the credentials and 'db' as the db name
    #
    #     InfluxDB::Client.new :username => 'username'       # override username, other defaults remain unchanged
    #
    #     Influxdb::Client.new 'db', :username => 'username' # override username, use 'db' as the db name
    #
    # === Valid options in hash
    #
    # +:host+:: the hostname to connect to
    # +:port+:: the port to connect to
    # +:username+:: the username to use when executing commands
    # +:password+:: the password associated with the username
    # +:use_ssl+:: use ssl to connect
    def initialize *args
      @database = args.first if args.first.is_a? String
      opts = args.last.is_a?(Hash) ? args.last : {}
      @hosts = Array(opts[:hosts] || opts[:host] || ["localhost"])
      @port = opts[:port] || 8086
      @username = opts[:username] || "root"
      @password = opts[:password] || "root"
      @use_ssl = opts[:use_ssl] || false
      @time_precision = opts[:time_precision] || "s"
      @initial_delay = opts[:initial_delay] || 0.01
      @max_delay = opts[:max_delay] || 30
      @open_timeout = opts[:write_timeout] || 5
      @read_timeout = opts[:read_timeout] || 300
      @async = opts[:async] || false
      @retry = opts.fetch(:retry) { true }

      @worker = InfluxDB::Worker.new(self) if @async

      at_exit { stop! }
    end

    ## allow options, e.g. influxdb.create_database('foo', replicationFactor: 3)
    def create_database(name, options = {})
      url = full_url("/db")
      options[:name] = name
      data = JSON.generate(options)
      post(url, data)
    end

    def delete_database(name)
      delete full_url("/db/#{name}")
    end

    def get_database_list
      get full_url("/db")
    end

    def create_cluster_admin(username, password)
      url = full_url("/cluster_admins")
      data = JSON.generate({:name => username, :password => password})
      post(url, data)
    end

    def update_cluster_admin(username, password)
      url = full_url("/cluster_admins/#{username}")
      data = JSON.generate({:password => password})
      post(url, data)
    end

    def delete_cluster_admin(username)
      delete full_url("/cluster_admins/#{username}")
    end

    def get_cluster_admin_list
      get full_url("/cluster_admins")
    end

    def create_database_user(database, username, password)
      url = full_url("/db/#{database}/users")
      data = JSON.generate({:name => username, :password => password})
      post(url, data)
    end

    def update_database_user(database, username, options = {})
      url = full_url("/db/#{database}/users/#{username}")
      data = JSON.generate(options)
      post(url, data)
    end

    def delete_database_user(database, username)
      delete full_url("/db/#{database}/users/#{username}")
    end

    def get_database_user_list(database)
      get full_url("/db/#{database}/users")
    end

    def get_database_user_info(database, username)
      get full_url("/db/#{database}/users/#{username}")
    end

    def alter_database_privilege(database, username, admin=true)
      update_database_user(database, username, :admin => admin)
    end

    # NOTE: Only cluster admin can call this
    def continuous_queries(database)
      get full_url("/db/#{database}/continuous_queries")
    end

    # EXAMPLE:
    #
    # db.create_continuous_query(
    #   "select mean(sys) as sys, mean(usr) as usr from cpu group by time(15m)",
    #   "cpu.15m",
    # )
    #
    # NOTE: Only cluster admin can call this
    def create_continuous_query(query, name)
      query("#{query} into #{name}")
    end

    # NOTE: Only cluster admin can call this
    def get_continuous_query_list
      query("list continuous queries")
    end
    
    # NOTE: Only cluster admin can call this
    def delete_continuous_query(id)
      query("drop continuous query #{id}")
    end

    def write_point(name, data, async=@async, time_precision=@time_precision)
      data = data.is_a?(Array) ? data : [data]
      columns = data.reduce(:merge).keys.sort {|a,b| a.to_s <=> b.to_s}
      payload = {:name => name, :points => [], :columns => columns}

      data.each do |point|
        payload[:points] << columns.inject([]) do |array, column|
          array << InfluxDB::PointValue.new(point[column]).dump
        end
      end

      if async
        worker.push(payload)
      else
        _write([payload], time_precision)
      end
    end

    def _write(payload, time_precision=@time_precision)
      url = full_url("/db/#{@database}/series", :time_precision => time_precision)
      data = JSON.generate(payload)
      post(url, data)
    end

    def query(query, time_precision=@time_precision)
      url = full_url("/db/#{@database}/series", :q => query, :time_precision => time_precision)
      series = get(url)

      if block_given?
        series.each { |s| yield s['name'], denormalize_series(s) }
      else
        series.reduce({}) do |col, s|
          name                  = s['name']
          denormalized_series   = denormalize_series s
          col[name]             = denormalized_series
          col
        end
      end
    end

    def stop!
      @stopped = true
    end

    def stopped?
      @stopped
    end

    private

    def full_url(path, params={})
      params[:u] = @username
      params[:p] = @password

      query = params.map { |k, v| [CGI.escape(k.to_s), "=", CGI.escape(v.to_s)].join }.join("&")

      URI::Generic.build(:path => path, :query => query).to_s
    end

    def get(url)
      connect_with_retry do |http|
        response = http.request(Net::HTTP::Get.new(url))
        if response.kind_of? Net::HTTPSuccess
          return JSON.parse(response.body)
        elsif response.kind_of? Net::HTTPUnauthorized
          raise InfluxDB::AuthenticationError.new response.body
        else
          raise InfluxDB::Error.new response.body
        end
      end
    end

    def post(url, data)
      headers = {"Content-Type" => "application/json"}
      connect_with_retry do |http|
        response = http.request(Net::HTTP::Post.new(url, headers), data)
        if response.kind_of? Net::HTTPSuccess
          return response
        elsif response.kind_of? Net::HTTPUnauthorized
          raise InfluxDB::AuthenticationError.new response.body
        else
          raise InfluxDB::Error.new response.body
        end
      end
    end

    def delete(url)
      connect_with_retry do |http|
        response = http.request(Net::HTTP::Delete.new(url))
        if response.kind_of? Net::HTTPSuccess
          return response
        elsif response.kind_of? Net::HTTPUnauthorized
          raise InfluxDB::AuthenticationError.new response.body
        else
          raise InfluxDB::Error.new response.body
        end
      end
    end

    def connect_with_retry(&block)
      hosts = @hosts.dup
      delay = @initial_delay

      begin
        hosts.push(host = hosts.shift)
        http = Net::HTTP.new(host, @port)
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
        http.use_ssl = @use_ssl
        block.call(http)

      rescue Timeout::Error, *InfluxDB::NET_HTTP_EXCEPTIONS => e
        log :error, "Failed to contact host #{host}: #{e.inspect} #{"- retrying in #{delay}s." if retry?}"
        log :info, "Queue size is #{@queue.length}." unless @queue.nil?
        stop! unless retry?
        if stopped?
          raise e
        else
          sleep delay
          delay = [@max_delay, delay * 2].min
          retry
        end
      ensure
        http.finish if http.started?
      end
    end

    def retry?
      !stopped? && @retry
    end

    def denormalize_series series
      columns = series['columns']

      h = Hash.new(-1)
      columns = columns.map {|v| h[v] += 1; h[v] > 0 ? "#{v}~#{h[v]}" : v }

      series['points'].map do |point|
        decoded_point = point.map do |value|
          InfluxDB::PointValue.new(value).load
        end
        Hash[columns.zip(decoded_point)]
      end
    end

    WORKER_MUTEX = Mutex.new
    def worker
      return @worker if @worker
      WORKER_MUTEX.synchronize do
        #this return is necessary because the previous mutex holder might have already assigned the @worker
        return @worker if @worker
        @worker = InfluxDB::Worker.new(self)
      end
    end
  end
end
