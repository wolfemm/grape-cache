# frozen_string_literal: true

require "msgpack"

module Grape
  module Cache
    module Backend
      class CacheEntryMetadata
        FULL_TIME_FORMAT = "%Y%m%d%H%M%S%N"

        attr_accessor :etag, :last_modified, :expire_at

        def initialize(*args)
          args.extract_options!.each { |key, value| send("#{key}=", value) }
        end

        def expired?(at_time = Time.now)
          self.expire_at && (self.expire_at < at_time)
        end

        def ==(value)
          %i[etag last_modified expire_at].all? { |prop| send(prop) == value.send(prop) }
        end

        def encode
          MessagePack.pack([etag, last_modified&.strftime(FULL_TIME_FORMAT), expire_at.to_i])
        end

        def self.decode(encoded_value)
          etag, last_modified, expire_at = MessagePack.unpack(encoded_value)

          unless last_modified.blank?
            last_modified = Time.zone.strptime(last_modified, FULL_TIME_FORMAT)
          end

          new({
            etag: etag,
            expire_at: Time.zone.at(expire_at.to_i),
            last_modified: last_modified,
          })
        end
      end
    end
  end
end
