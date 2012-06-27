#! /usr/bin/env ruby
require 'optparse'
require 'torchat'

require 'eventmachine'
require 'em-websocket'
require 'evma_httpserver'

options = {}

OptionParser.new do |o|
	options[:web] = {
		host: '127.0.0.1',
		port: 11110
	}

	options[:websocket] = {
		host: '127.0.0.1',
		port: 11111
	}

	o.on '-p', '--profile NAME', 'the profile name' do |name|
		options[:profile] = name
	end

	o.on '-c', '--config PATH', 'the path to the config file' do |path|
		options[:config] = path
	end

	o.on '-t', '--tor', 'enable automatic generation and run of Tor' do
		options[:tor] = true
	end

	o.on '-l', '--listen HOST:PORT...', Array, 'the host and port to listen on' do |value|
		host, port = value.first.split(':')

		options[:web][:host] = host      if host
		options[:web][:port] = port.to_i if port

		host, port = value.last.split(':')

		options[:websocket][:host] = host      if host
		options[:websocket][:port] = port.to_i if port
	end

	o.on '-s', '--ssl KEY:CERT', 'the private key and cert files' do |path|
		options[:ssl] = { key: path.split(':').first, cert: path.split(':').last }
	end

	o.on '-P', '--password PASSWORD' do |password|
		options[:password] = password
	end

	o.on '-o', '--online' do
		options[:online] = true
	end

	o.on '-d', '--debug [LEVEL=1]', 'enable debug mode' do |value|
		ENV['DEBUG'] = value || ?1
	end
end.parse!

class TorchatWebUI
	class WebsocketConnection < EM::WebSocket::Connection
		attr_accessor :daemon, :host, :port, :ssl

		def authorized?; @authorized;        end
		def authorize!;  @authorized = true; end

		def post_init

		end

		def unbind
			@daemon.connections.delete self
		end
	end

	class WebConnection < EM::Connection
		include EM::HttpServer

		attr_accessor :ssl

		def post_init
			super

			no_environment_strings
		end

		def process_http_request
			# the http request details are available via the following instance variables:
			#   @http_protocol
			#   @http_request_method
			#   @http_cookie
			#   @http_if_none_match
			#   @http_content_type
			#   @http_path_info
			#   @http_request_uri
			#   @http_query_string
			#   @http_post_content
			#   @http_headers

			response = EM::DelegatedHttpResponse.new(self)
			response.status = 200
			response.content_type 'text/html'
			response.content = '<center><h1>Hi there</h1></center>'
			response.send_response
		end
	end

	attr_reader   :password, :connections
	attr_accessor :profile, :tor

	def initialize (password = nil, file_transfer_ports = [])
		@password    = password
		@buddies     = []
		@connections = []
		@pings       = Hash.new { |h, k| h[k] = {} }

		yield self if block_given?
	end

	def start (web, websocket, ssl = nil)
		return if @started

		@started = true

		@websocket = EM.start_server websocket[:host], websocket[:port], WebsocketConnection do |conn|
			@connections << conn

			conn.daemon = self
			conn.host   = host
			conn.port   = port
			conn.ssl    = ssl

			unless @password
				conn.authorize!
			end
		end

		@web = EM.start_server web[:host], web[:port], WebConnection do |conn|
			conn.ssl = ssl
		end
	end

	def stop
		EM.stop_server @websocket
		EM.stop_server @web

		profile.stop
		tor.stop if tor
	end

	def process (connection, line)
		command, rest = line.force_encoding('UTF-8').split(' ', 2)

		case command.downcase.to_sym
		when :starttls
			if connection.ssl
				connection.start_tls(private_key_file: connection.ssl[:key], cert_chain_file: connection.ssl[:cert])
			else
				connection.start_tls
			end

			return

		when :pass
			if !@password || @password == rest
				connection.authorize!
				connection.send_response "AUTHORIZED #{profile.session.id}"
			end

			return
		end

		unless connection.authorized?
			connection.send_response "UNAUTHORIZED #{command}"
			return
		end

		case command.downcase.to_sym
		when :whoami
			connection.send_response "WHOAMI #{profile.id}"

		when :list
			connection.send_response "LIST #{profile.buddies.keys.join(' ')}"

		when :remove
			profile.buddies.remove rest

		when :add
			attribute, rest = rest.split(' ')

			if rest && attribute == 'tmp'
				profile.buddies.add_temporary rest
			else
				profile.buddies.add attribute
			end

		when :typing
			id, mode = rest.split(' ')

			if buddy = profile.buddies[id]
				buddy.send_typing(mode)
			end

		when :status
			if rest && Torchat.normalize_id(rest, true)
				if buddy = profile.buddies[rest]
					connection.send_response "#{rest} STATUS #{buddy.status}"
				end
			else
				profile.status = rest
			end

		when :client
			if buddy = profile.buddies[rest]
				if buddy.client.name
					connection.send_response "#{rest} CLIENT_NAME #{buddy.client.name}"
				end

				if buddy.client.version
					connection.send_response "#{rest} CLIENT_VERSION #{buddy.client.version}"
				end
			end

		when :name
			if rest && Torchat.normalize_id(rest, true)
				if buddy = profile.buddies[rest]
					connection.send_response "#{rest} NAME #{buddy.name}"
				end
			else
				profile.name = rest
			end

		when :description
			if rest && Torchat.normalize_id(rest, true)
				if buddy = profile.buddies[rest]
					connection.send_response "#{rest} DESCRIPTION #{buddy.description}"
				end
			else
				profile.description = rest
			end

		when :message
			profile.send_message_to *rest.split(' ', 2)

		when :block
			profile.buddies[rest].block!

		when :allow
			profile.buddies[rest].allow!

		when :broadcast
			profile.send_broadcast rest

		when :groupchats
			connection.send_response "GROUPCHATS #{profile.group_chats.keys.join(' ')}"

		when :groupchat_participants
			if group_chat = profile.group_chats[rest]
				connection.send_response "GROUPCHAT_PARTICIPANTS #{group_chat.id} #{group_chat.participants.keys.join ' '}"
			end

		when :groupchat_invite
			group_chat, buddy = rest.split ' '

			if buddy
				if (buddy = profile.buddies[buddy]) && (group_chat = profile.group_chats[group_chat])
					group_chat.invite(buddy)
				end
			else
				if buddy = profile.buddies[group_chat]
					profile.group_chats.create.invite(buddy)
				end
			end

		when :groupchat_leave
			group_chat, reason = rest.split ' ', 2

			if group_chat = profile.group_chats[group_chat]
				group_chat.leave reason
			end

		when :groupchat_message
			group_chat, message = rest.split ' ', 2

			if group_chat = profile.group_chats[group_chat]
				group_chat.send_message message
			end

		when :latency
			id, rest = rest.split ' ', 2

			if (buddy = profile.buddies[id]) && buddy.supports?(:latency)
				@pings[id][buddy.latency.ping!.id] = [Time.now, rest]
			end

		else
			connection.send_response "UNIMPLEMENTED #{command}"
		end
	rescue => e
		Torchat.debug e
	end

	def received_packet (packet)
		return unless @buddies.include? packet.from

		if packet.type == :message
			packet.to_s.lines.each {|line|
				send_everyone "#{packet.from.id} MESSAGE #{line}"
			}
		elsif packet.type == :status
			send_everyone "#{packet.from.id} STATUS #{packet}"
		elsif packet.type == :client
			send_everyone "#{packet.from.id} CLIENT_NAME #{packet}"
		elsif packet.type == :version
			send_everyone "#{packet.from.id} CLIENT_VERSION #{packet}"
		elsif packet.type == :profile_name && !packet.nil?
			send_everyone "#{packet.from.id} NAME #{packet}"
		elsif packet.type == :profile_text && !packet.nil?
			send_everyone "#{packet.from.id} DESCRIPTION #{packet}"
		elsif packet.type == :remove_me
			send_everyone "#{packet.from.id} REMOVE"
		end
	end

	def file_transfer (what, file_transfer, *args)
		if what == :start

		elsif what == :stop

		elsif what == :complete

		end
	end

	def typing (buddy, mode)
		send_everyone "#{buddy.id} TYPING #{mode}"
	end

	def broadcast (message)
		send_everyone "BROADCAST #{message}"
	end

	def group_chat (what, group_chat, buddy = nil, *args)
		if what == :create
			send_everyone "GROUPCHAT_CREATE #{group_chat.id}"
		elsif what == :invite
			send_everyone "#{buddy.id} GROUPCHAT_INVITE #{group_chat.id}"
		elsif what == :join
			send_everyone "#{buddy.id} GROUPCHAT_JOIN #{group_chat.id}#{" #{args.first.id}" if args.first}"
		elsif what == :joined
			send_everyone "GROUPCHAT_JOINED #{group_chat.id}"
			send_everyone "GROUPCHAT_PARTICIPANTS #{group_chat.id} #{group_chat.participants.keys.join ' '}"
		elsif what == :leave
			send_everyone "#{buddy.id} GROUPCHAT_LEAVE #{group_chat.id}#{" #{args.first}" if args.first}"
		elsif what == :left
			send_everyone "GROUPCHAT_LEFT #{group_chat.id} #{args.first}"
		elsif what == :message
			send_everyone "#{buddy.id} GROUPCHAT_MESSAGE #{group_chat.id} #{args.first}"
		elsif what == :destroy
			send_everyone "GROUPCHAT_DESTROY #{group_chat.id}"
		end
	end

	def latency (buddy, amount, id)
		send_everyone "#{buddy.id} LATENCY #{@pings[buddy.id].delete(id).last}"
	end

	def cleanup!
		@pings.each {|id, pings|
			pings.reject! {|time, payload|
				(Time.now - time).to_i >= 80
			}
		}

		@pings.reject!(&:empty?)
	end

	def connected?; @connected; end

	def connected (buddy)
		@buddies << buddy

		send_everyone "#{buddy.id} CONNECTED"

		send_everyone "#{buddy.id} NAME #{buddy.name}"               if buddy.name
		send_everyone "#{buddy.id} DESCRIPTION #{buddy.description}" if buddy.description

		if buddy.client.name
			send_everyone "#{buddy.id} CLIENT_NAME #{buddy.client.name}"
		end

		if buddy.client.version
			send_everyone "#{buddy.id} CLIENT_VERSION #{buddy.client.version}"
		end
	end

	def disconnected (buddy)
		return unless @buddies.include? buddy

		send_everyone "#{buddy.id} DISCONNECTED"

		@buddies.delete buddy
	end

	def removed (buddy)
		return unless @buddies.include? buddy

		send_everyone "#{buddy.id} REMOVE"
	end

	def send_everyone (text, even_unauthorized = false)
		@connections.each {|connection|
			next unless connection.authorized? || even_unauthorized

			connection.send_response text
		}
	end
end

EM.run {
	Torchatd.new(options[:password], options[:file_transfer_ports]) {|d|
		d.profile = options[:config] ? Torchat.new(options[:config]) : Torchat.profile(options[:profile])

		puts 'torchat-web-ui starting...'

		if options[:tor]
			d.profile.tor.file = 'torrc.txt'

			d.profile.tor.start "#{d.profile.path || '~/.torchat'}/Tor", -> {
				abort 'could not load the onion id' if 20.times {
					break if File.exists? 'hidden_service/hostname'

					sleep 1
				}
			}, -> {
				abort 'tor exited with errors'
			}
		end

		unless d.profile.config['id']
			if d.profile.path
				if File.readable?("#{d.profile.path}/Tor/hidden_service/hostname")
					d.profile.config['id'] = File.read("#{d.profile.path}/Tor/hidden_service/hostname")[/^(.*?)\.onion/, 1]
				end
			end or abort 'could not deduce the onion id'
		end

		puts "torchat-web-ui started for #{d.profile.config['id']} on http://#{options[:host]}:#{options[:port]}"

		%w[INT KILL].each {|sig|
			trap sig do
				puts 'torchat-web-ui stopping...'

				d.stop

				EM.stop_event_loop
			end
		}

		d.profile.start {|s|
			s.on :connect_to do |e|
				Torchat.debug "connecting to #{e.address}:#{e.port}"
			end

			s.on :connect_failure do |e|
				Torchat.debug "#{e.buddy.id} failed to connect"
			end

			s.on :connect do |e|
				Torchat.debug "#{e.buddy.id} connected"
			end

			s.on :verify do |e|
				Torchat.debug "#{e.buddy.id} has been verified"
			end

			s.on :ready do |e|
				d.connected e.buddy
			end

			s.on :remove_buddy do |e|
				d.removed e.buddy
			end

			s.on :disconnect do |e|
				Torchat.debug "#{e.buddy.id} disconnected"

				d.disconnected e.buddy
			end

			s.on_packet do |e|
				d.received_packet e.packet unless e.packet.extension
			end

			s.on :file_transfer_start do |e|
				d.file_transfer :start, e.file_transfer
			end

			s.on :file_transfer_stop do |e|
				d.file_transfer :stop, e.file_transfer
			end

			s.on :file_transfer_complete do |e|
				d.file_transfer :complete, e.file_transfer
			end

			s.on :typing do |e|
				d.typing e.buddy, e.mode
			end

			s.on :broadcast do |e|
				d.broadcast e.message
			end

			s.on :group_chat_create do |e|
				d.group_chat :create, e.group_chat
			end

			s.on :group_chat_invite do |e|
				d.group_chat :invite, e.group_chat, e.buddy
			end

			s.on :group_chat_join do |e|
				if e.buddy
					d.group_chat :join, e.group_chat, e.buddy, e.invited_by
				else
					d.group_chat :joined, e.group_chat, nil, e.invited_by
				end
			end

			s.on :group_chat_message do |e|
				d.group_chat :message, e.group_chat, e.buddy, e.message
			end

			s.on :group_chat_leave do |e|
				if e.buddy
					d.group_chat :leave, e.group_chat, e.buddy, e.reason
				else
					d.group_chat :left, e.group_chat, nil, e.reason
				end
			end

			s.on :group_chat_destroy do |e|
				d.group_chat :destroy, e.group_chat
			end

			s.on :latency do |e|
				d.latency e.buddy, e.amount, e.id
			end

			s.online! if options[:online]
		}

		EM.add_periodic_timer 60 do
			d.cleanup!
		end
	}.start(options[:web], options[:websocket], options[:ssl])
}
