# frozen_string_literal: true

require 'discordrb/events/generic'
require 'discordrb/data'

module Discordrb::Events
  # Event raised when a user's voice state updates
  class VoiceStateUpdateEvent < Event
    attr_reader :user, :suppress, :session_id, :self_mute, :self_deaf, :mute, :deaf, :server, :channel

    # @return [Channel, nil] the old channel this user was on, or nil if the user is newly joining voice.
    attr_reader :old_channel

    def initialize(data, old_channel_id, bot)
      @bot = bot

      @suppress = data['suppress']
      @session_id = data['session_id']
      @self_mute = data['self_mute']
      @self_deaf = data['self_deaf']
      @mute = data['mute']
      @deaf = data['deaf']
      @server = bot.server(data['guild_id'].to_i)
      return unless @server

      @channel = bot.channel(data['channel_id'].to_i) if data['channel_id']
      @old_channel = bot.channel(old_channel_id) if old_channel_id
      @user = bot.user(data['user_id'].to_i)
    end
  end

  # Event handler for VoiceStateUpdateEvent
  class VoiceStateUpdateEventHandler < EventHandler
    def matches?(event)
      # Check for the proper event type
      return false unless event.is_a? VoiceStateUpdateEvent

      name_or_id = proc do |a, e|
        a == if a.is_a? String
               e.name
             elsif a.is_a? Integer
               e.id
             else
               e
             end
      end

      # Don't bother if the channel is nil
      chan_name_or_id = proc { |a, e| name_or_id.call(a, e) if e }

      # Accept 'true', or 'false' as a user set value
      bool_or_str = proc do |a, e|
        a == if a.is_a?(String)
               e.to_s
             else
               e
             end
      end

      [
        matches_all(@attributes[:from], event.user, &name_or_id),
        matches_all(@attributes[:mute], event.mute, &bool_or_str),
        matches_all(@attributes[:deaf], event.deaf, &bool_or_str),
        matches_all(@attributes[:self_mute], event.self_mute, &bool_or_str),
        matches_all(@attributes[:self_deaf], event.self_deaf, &bool_or_str),
        matches_all(@attributes[:channel], event.channel, &chan_name_or_id),
        matches_all(@attributes[:old_channel], event.old_channel, &chan_name_or_id)
      ].reduce(true, &:&)
    end
  end
end
