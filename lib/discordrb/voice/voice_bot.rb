require 'discordrb/voice/encoder'

require 'faye/websocket'
require 'eventmachine'

require 'resolv'
require 'socket'
require 'json'

module Discordrb::Voice
  # A voice connection consisting of a UDP socket and a websocket client
  class VoiceBot
    def initialize(channel, bot, token, session, endpoint)
      @channel = channel
      @bot = bot
      @token = token
      @session = session
      @endpoint = endpoint
      @endpoint.delete(':80')

      @encoder = Encoder.new
      bot.debug('Initing connections...')
      init_connections
    end

    def speaking=(value)
      @playing = value
      data = {
        op: 5,
        d: {
          speaking: value,
          delay: 0
        }
      }
      @ws.send(data.to_json)
    end

    def play_raw(io)
      start_time = Time.now.to_f
      sequence = time = count = 0
      length = 20.0
      @playing = true
      @on_warning = false

      self.speaking = true
      loop do
        unless playing
          self.speaking = false
          break
        end

        buf = io.read(1920)
        unless buf
          sleep length * 10.0
          continue
        end

        if buf.length != 1920
          if @on_warning
            io.close
            self.speaking = false
            break
          else
            sleep length * 10.0
            continue
          end
        end

        count += 1

        (sequence + 10 < 65_535) ? sequence += 1 : sequence = 0
        (time + 9600 < 4_294_967_295) ? time += 960 : time = 0

        send_buffer(buf, sequence, time)

        @stream_time = count * length
        next_time = start_time + @stream_time
        delay = length + (next_time - Time.now.to_f)

        self.speaking = true unless @playing

        sleep delay
      end
    end

    def send_packet(packet)
      @playing = true
      @udp.send(packet, 0, @ws_data['port'], @endpoint)
    rescue
      @playing = false
      nil
    end

    def make_packet(buf, sequence, time, ssrc)
      [0x80, 0x78, sequence, time, ssrc].pack('CCnNN') + buf
    end

    def send_buffer(raw_buf, sequence, time)
      @playing = true
      packet = make_packet(@encoder.encode(raw_buf), sequence, time, @ws_data['ssrc'])
      send_packet(packet)
    rescue
      nil
    end

    def stop_playing
      @file_io.close if @file_io
      @ws_thread.kill if @ws_thread
      @heartbeat_thread.kill if @heartbeat_thread
      @playing = false
    end

    alias_method :destroy, :stop_playing

    def play_file(file)
      @file_io = @encoder.encode_file(file)
      play_raw(@file_io)
    end

    private

    def lookup_endpoint
      @orig_endpoint = @endpoint
      @bot.debug("Resolving voice endpoint #{@endpoint}")
      @endpoint = @endpoint[6..-1] if @endpoint.start_with? 'wss://'
      @endpoint.delete!(':80') # The endpoint may contain a port, we don't want that
      @endpoint = Resolv.getaddress @endpoint
      @bot.debug("Got voice endpoint IP: #{@endpoint}")
    end

    def init_udp
      @bot.debug('Initializing UDP')
      @udp = UDPSocket.new
    end

    def init_ws
      EM.run do
        @bot.debug('Opening VWS')
        host = "wss://#{@orig_endpoint.delete(':80')}"
        @bot.debug("Host: #{host}")
        @ws = Faye::WebSocket::Client.new(host)
        @bot.debug('VWS connected')

        puts @ws
        puts @ws.status

        @ws.on(:open) do
          @bot.debug('VWS opened')
          # Send init packet
          data = {
            op: 0,
            d: {
              server_id: @channel.server.id,
              user_id: @bot.bot_user.id,
              session_id: @session,
              token: @token
            }
          }

          @ws.send(data.to_json)
          @bot.debug('VWS init packet sent!')
        end
        @ws.on(:message) { |event| websocket_message(event) }
        @ws.on(:error) { |event| @bot.debug(event.message) }
        @bot.debug('VWS opened with events')
      end
      @bot.debug('VWS EM exited, wat')
    end

    def send_heartbeat
      millis = Time.now.strftime('%s%L').to_i
      debug("Sending voice heartbeat at #{millis}")
      data = {
        'op' => 3,
        'd' => nil
      }

      @ws.send(data.to_json)
    end

    def websocket_message(event)
      packet = JSON.parse(event.data)
      @bot.debug("Received VWS message! #{event.data}")

      case packet['op']
        # Opcode 2 (see below)
      when 2
        @bot.debug('Got opcode 2 packet!')
        @ws_data = packet['d']

        @heartbeat_interval = @ws_data['heartbeat_interval']
        @heartbeat_thread = Thread.new do
          loop do
            sleep @heartbeat_interval
            send_heartbeat
          end
        end

        to_send = [@ws_data['ssrc']].pack('N')
        # Add 66 zeros so the buffer is 70 long
        to_send += '\0' * 66
        # Send UDP discovery
        @bot.debug("Sending UDP discovery: #{to_send}")
        @udp.send(to_send, 0, @endpoint, @ws_data['port'])
      when 4
        @ws_data = packet['d']
        @ready = true
        @mode = @ws_data['mode']
      end
    end

    # Communication goes like this:
    # me                    discord
    #   |                      |
    # websocket connect ->     |
    #   |                      |
    #   |     <- websocket opcode 2
    #   |                      |
    # UDP discovery ->         |
    #   |                      |
    #   |       <- UDP reply packet
    #   |                      |
    # websocket opcode 1 ->    |
    #   |                      |
    # ...
    def init_connections
      lookup_endpoint
      init_udp
      # Connect websocket
      @ws_thread = Thread.new { init_ws; @bot.debug('all of my wat') }

      # Now wait for opcode 2 and the resulting UDP reply packet
      @bot.debug('Waiting for recv')
      message = @udp.recvmsg
      @bot.debug("Received message #{message}")
      ip = message[4..message.index("\0")].delete("\0")
      port = message[-2..-1].to_i

      @bot.debug("IP is #{ip}, Port is #{port}")

      # Send ws init packet (opcode 1)
      data = {
        op: 1,
        d: {
          protocol: 'udp',
          data: {
            address: ip,
            port: port,
            mode: @ws_data['modes'][0]
          }
        }
      }

      @ws.send(data.to_json)
      @bot.debug('VWS protocol init packet sent (opcode 1)!')
    end
  end
end
