require 'new_relic/rack/agent_hooks'
require 'new_relic/agent/thread'

module NewRelic
  module Agent

    class CrossAppMonitor

      module EncodingFunctions

        module_function

        def obfuscate_with_key(key, text)
          [ encode_with_key(key, text) ].pack('m').chomp
        end

        def decode_with_key(key, text)
          encode_with_key( key, text.unpack('m').first )
        end

        def encode_with_key(key, text)
          return text unless key
          key = key.bytes.to_a if key.respond_to?( :bytes )

          encoded = ""
          index = 0
          text.each_byte do |byte|
            encoded.concat((byte ^ key[index % key.length].to_i))
            index+=1
          end
          encoded
        end

      end
      include EncodingFunctions


      def initialize(events = nil)
        # When we're starting up for real in the agent, we get passed the events
        # Other spots can pull from the agent, during startup the agent doesn't exist yet!
        events ||= Agent.instance.events
        @trusted_ids = []

        events.subscribe(:finished_configuring) do
          finish_setup(Agent.config)
          register_event_listeners
        end
      end

      def finish_setup(config)
        @cross_app_id = config[:cross_process_id]
        @encoding_key = config[:encoding_key]
        @trusted_ids = config[:trusted_account_ids] || []
      end

      # Expected sequence of events:
      #   :before_call will save our cross application request id to the thread
      #   :start_transaction will get called when a transaction starts up
      #   :after_call will write our response headers/metrics and clean up the thread
      def register_event_listeners
        NewRelic::Agent.logger.
          debug("Wiring up Cross Application Tracing to events after finished configuring")

        events = Agent.instance.events
        events.subscribe(:before_call) do |env|
          save_client_cross_app_id(env)
        end

        events.subscribe(:start_transaction) do |name|
          set_transaction_custom_parameters
        end

        events.subscribe(:after_call) do |env, (status_code, headers, body)|
          insert_response_header(env, headers)
        end

        events.subscribe(:notice_error) do |_, options|
          set_error_custom_parameters(options)
        end
      end

      # Because we aren't in the right spot when our transaction actually
      # starts, hold client_cross_app_id we get thread local until then.
      THREAD_ID_KEY = :newrelic_client_cross_app_id

      def save_client_cross_app_id(request_headers)
        if should_process_request(request_headers)
          NewRelic::Agent::AgentThread.current[THREAD_ID_KEY] = decoded_id(request_headers)
        end
      end

      def clear_client_cross_app_id
        NewRelic::Agent::AgentThread.current[THREAD_ID_KEY] = nil
      end

      def client_cross_app_id
        NewRelic::Agent::AgentThread.current[THREAD_ID_KEY]
      end

      def insert_response_header(request_headers, response_headers)
        unless client_cross_app_id.nil?
          timings = NewRelic::Agent::BrowserMonitoring.timings
          content_length = content_length_from_request(request_headers)

          set_response_headers(response_headers, timings, content_length)
          set_metrics(client_cross_app_id, timings)

          clear_client_cross_app_id
        end
      end

      def should_process_request(request_headers)
        return cross_app_enabled? &&
            @cross_app_id &&
            trusts?(request_headers)
      end

      def cross_app_enabled?
        Agent.config[:cross_application_tracing]
      end

      # Expects an ID of format "12#345", and will only accept that!
      def trusts?(request)
        id = decoded_id(request)
        split_id = id.match(/(\d+)#\d+/)
        return false if split_id.nil?

        @trusted_ids.include?(split_id.captures.first.to_i)
      end

      def set_response_headers(response_headers, timings, content_length)
        response_headers['X-NewRelic-App-Data'] = build_payload(timings, content_length)
      end

      def build_payload(timings, content_length)

        # FIXME The transaction name might not be properly encoded.  use a json generator
        # For now we just handle quote characters by dropping them
        transaction_name = timings.transaction_name.gsub(/["']/, "")

        payload = %[["#{@cross_app_id}","#{transaction_name}",#{timings.queue_time_in_seconds},#{timings.app_time_in_seconds},#{content_length}] ]
        payload = obfuscate_with_key(@encoding_key, payload)
      end

      def set_transaction_custom_parameters
        # We expect to get the before call to set the id (if we have it) before
        # this, and then write our custom parameter when the transaction starts
        NewRelic::Agent.add_custom_parameters(:client_cross_app_id => client_cross_app_id) unless client_cross_app_id.nil?
      end

      def set_error_custom_parameters(options)
        options[:client_cross_app_id] = client_cross_app_id unless client_cross_app_id.nil?
      end

      def set_metrics(id, timings)
        metric = NewRelic::Agent.instance.stats_engine.get_stats_no_scope("ClientApplication/#{id}/all")
        metric.record_data_point(timings.app_time_in_seconds)
      end

      NEWRELIC_ID_HEADER = 'X-NewRelic-ID'
      NEWRELIC_ID_HEADER_KEYS = %W{#{NEWRELIC_ID_HEADER} HTTP_X_NEWRELIC_ID X_NEWRELIC_ID}
      CONTENT_LENGTH_HEADER_KEYS = %w{Content-Length HTTP_CONTENT_LENGTH CONTENT_LENGTH}

      def decoded_id(request)
        encoded_id = from_headers(request, NEWRELIC_ID_HEADER_KEYS)
        return "" if encoded_id.nil?

        decode_with_key(@encoding_key, encoded_id)
      end

      def content_length_from_request(request)
        from_headers(request, CONTENT_LENGTH_HEADER_KEYS) || -1
      end


      private

      def from_headers(request, try_keys)
        # For lookups, upcase all our keys on both sides just to be safe
        upcased_keys = try_keys.map{|k| k.upcase}
        upcased_keys.each do |header|
          found_key = request.keys.find { |k| k.upcase == header }
          return request[found_key] unless found_key.nil?
        end
        nil
      end

    end

  end
end

