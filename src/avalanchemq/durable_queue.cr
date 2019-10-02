require "file_utils"
require "./queue"

module AvalancheMQ
  class DurableQueue < Queue
    MAX_ACKS = 4 * 1024**2
    @durable = true

    def initialize(@vhost : VHost, @name : String,
                   @exclusive : Bool, @auto_delete : Bool,
                   @arguments : Hash(String, AMQP::Field))
      super
      @index_dir = File.join(@vhost.data_dir, Digest::SHA1.hexdigest @name)
      @log.debug { "Index dir: #{@index_dir}" }
      Dir.mkdir_p @index_dir
      @enq = File.open(File.join(@index_dir, "enq"), "a+")
      @enq.buffer_size = Config.instance.file_buffer_size
      @enq.sync = true
      @ack = File.open(File.join(@index_dir, "ack"), "a+")
      @ack.buffer_size = Config.instance.file_buffer_size
      @ack.sync = true
      @acks = 0_u32
      @ack_lock = Mutex.new
      @enq_lock = Mutex.new
      restore_index
    end

    private def compact_index! : Nil
      @log.info { "Compacting index" }
      @enq.close
      Dir.mkdir_p @index_dir
      @enq_lock.synchronize do
        File.open(File.join(@index_dir, "enq.tmp"), "w") do |f|
          unacked = @consumers.flat_map { |c| c.unacked.to_a }.sort.each
          next_unacked = unacked.next
          @ready_lock.synchronize do
            @ready.each do |sp|
              while next_unacked != Iterator::Stop::INSTANCE && next_unacked.as(SegmentPosition) < sp
                f.write_bytes next_unacked.as(SegmentPosition)
                next_unacked = unacked.next
              end
              f.write_bytes sp
            end
          end
          until next_unacked == Iterator::Stop::INSTANCE
            f.write_bytes next_unacked.as(SegmentPosition)
            next_unacked = unacked.next
          end
          f.fsync
        end
        File.rename File.join(@index_dir, "enq.tmp"), File.join(@index_dir, "enq")
        @enq = File.open(File.join(@index_dir, "enq"), "a")
        @enq.sync = true
        @enq.buffer_size = Config.instance.file_buffer_size
      end
      @ack_lock.synchronize do
        @ack.truncate
        @acks = 0_u32
      end
    end

    def close : Bool
      super.tap do |closed|
        next unless closed
        compact_index! unless @deleted
        @log.debug { "Closing index files" }
        @ack.close
        @enq.close
      end
    end

    def delete
      FileUtils.rm_rf @index_dir if super
    end

    def publish(sp : SegmentPosition, persistent = false) : Bool
      super || return false
      if persistent
        @enq_lock.synchronize do
          @enq.write_bytes sp
        end
      end
      true
    end

    def get(no_ack : Bool, &blk : Envelope? -> Nil)
      super(no_ack) do |env|
        if env && no_ack
          persistent = env.message.properties.delivery_mode.try { 0_u8 } == 2_u8
          if persistent
            @ack_lock.synchronize do
              @ack.write_bytes env.segment_position
            end
            compact_index! if (@acks += 1) > MAX_ACKS
          end
        end
        yield env
      end
    end

    def ack(sp : SegmentPosition, persistent : Bool)
      if persistent
        @ack_lock.synchronize do
          @ack.write_bytes sp
        end
        compact_index! if (@acks += 1) > MAX_ACKS
      end
      super
    end

    def purge
      @log.info "Purging"
      @enq_lock.synchronize do
        @enq.truncate
      end
      @ack_lock.synchronize do
        @ack.truncate
      end
      @acks = 0_u32
      super
    end

    def fsync_enq
      return if @closed
      @log.debug "fsyncing enq"
      @enq.fsync(flush_metadata: false)
    end

    def fsync_ack
      return if @closed
      @log.debug "fsyncing ack"
      @ack.fsync(flush_metadata: false)
    end

    private def restore_index
      @log.info "Restoring index"
      @ack.rewind
      sp_size = sizeof(SegmentPosition)
      acked = Array(SegmentPosition).new(@ack.size // sp_size)
      loop do
        acked << SegmentPosition.from_io @ack
        @acks += 1
      rescue IO::EOFError
        break
      end
      # to avoid repetetive allocations in Dequeue#increase_capacity
      # we redeclare the ready queue with a larger initial capacity
      capacity = Math.max(@enq.size.to_i64 - @ack.size, sp_size) // sp_size
      @ready = Deque(SegmentPosition).new(capacity)
      @enq.rewind
      loop do
        sp = SegmentPosition.from_io @enq
        @ready << sp unless acked.includes? sp
      rescue IO::EOFError
        break
      end
      @log.info { "#{message_count} messages" }
      message_available if message_count > 0
    rescue ex : Errno
      @log.error { "Could not restore index: #{ex.inspect}" }
    end
  end
end
