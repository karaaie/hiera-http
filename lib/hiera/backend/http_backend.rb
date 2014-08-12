class Hiera
  module Backend
    class Http_backend

      def initialize
        require 'net/http'
        require 'net/https'
        @config = Config[:http]

        #these are keys that we're actually going to try to lookup
        #this is a performance optimization to remove http calls which we know
        #before hand will not yield any result.
        #an empty set indicates that it will try to lookup all given keys.
        #@available_keys = @config[:keys] || []

        @http = Net::HTTP.new(@config[:host], @config[:port])
        @http.read_timeout = @config[:http_read_timeout] || 10
        @http.open_timeout = @config[:http_connect_timeout] || 10

        if @config[:use_ssl]
          @http.use_ssl = true
          if @config[:ssl_cert]
            @http.verify_mode = OpenSSL::SSL::VERIFY_PEER
            store = OpenSSL::X509::Store.new
            store.add_cert(OpenSSL::X509::Certificate.new(File.read(@config[:ssl_ca_cert])))
            @http.cert_store = store

            @http.key = OpenSSL::PKey::RSA.new(File.read(@config[:ssl_cert]))
            @http.cert = OpenSSL::X509::Certificate.new(File.read(@config[:ssl_key]))
          end
        else
          @http.use_ssl = false
        end
      end

      # Handlers
      # Here we define specific handlers to parse the output of the http request
      # and return a value. Currently we support YAML and JSON
      #
      def json_handler(key,answer)
        require 'rubygems'
        require 'json'
        JSON.parse(answer)[key]
      end

      def yaml_handler(key,answer)
        begin
          require 'yaml'
          y = YAML.load answer
          y[key]
        rescue Exception => e
          $stderr.puts "failed to parse: #{e.message}"
          $stderr.puts e.backtrack
        end
      end

      def parse_response(key,answer)

        return nil unless answer

        Hiera.debug("[hiera-http]: Query returned data, parsing response as #{@config[:output] || 'plain'}")

        case @config[:output]

          when 'plain'
            # When the output format is configured as plain we assume that if the
            # endpoint URL returns an HTTP success then the contents of the response
            # body is the value itself, or nil.
            #
            answer
          when 'json'
            # If JSON is specified as the output format, assume the output of the
            # endpoint URL is a JSON document and return keypart that matched our
            # lookup key
            self.json_handler(key,answer)
          when 'yaml'
            # If YAML is specified as the output format, assume the output of the
            # endpoint URL is a YAML document and return keypart that matched our
            # lookup keyi
            $stderr.puts 'yaml case'
            self.yaml_handler(key,answer)
          else
            answer
        end
      end

      def lookup(key, scope, order_override, resolution_type)

        #stop execution if the key is not pre-configured.
        #unless @available_keys.include?(key) and not @available_keys.empty? do
        #  return nil
        #end

        answer = nil

        paths = @config[:paths].map { |p| Backend.parse_string(p, scope, { 'key' => key }) }
        paths.insert(0, order_override) if order_override

        paths.each do |path|

          Hiera.debug("[hiera-http]: Lookup #{key} from #{@config[:host]}:#{@config[:port]}#{path}")
          httpreq = Net::HTTP::Get.new(path)

          begin
            httpres = @http.request(httpreq)
            Hiera.debug("[hiera-http]: result receivied #{httpres}")
          rescue Exception => e
            Hiera.warn("[hiera-http]: Net::HTTP threw exception #{e.message}")
            raise Exception, e.message unless @config[:failure] == 'graceful'
            next
          end

          unless httpres.kind_of?(Net::HTTPSuccess)
            Hiera.debug("[hiera-http]: bad http response from #{@config[:host]}:#{@config[:port]}#{path}")
            Hiera.debug("HTTP response code was #{httpres.code}")
            unless ( httpres.code == '404' && @config[:ignore_404] == true )
              raise Exception, 'Bad HTTP response' unless @config[:failure] == 'graceful'
            end
            next
          end

          result = self.parse_response(key, httpres.body)
          next unless result

          parsed_result = Backend.parse_answer(result, scope)

          case resolution_type
            when :array
              answer ||= []
              answer << parsed_result
            when :hash
              answer ||= {}
              answer = parsed_result.merge answer
            else
              answer = parsed_result
              break
          end
        end
        answer
      end
      
    end
  end
end
