require "./spec_helper"

describe LavinMQ::PriorityQueue do
  it "should prioritize messages" do
    with_channel do |ch|
      q_args = AMQP::Client::Arguments.new({"x-max-priority" => 10})
      q = ch.queue("", args: q_args)
      q.publish "prio2", props: AMQP::Client::Properties.new(priority: 2)
      q.publish "prio1", props: AMQP::Client::Properties.new(priority: 1)
      q.get(no_ack: true).try(&.body_io.to_s).should eq("prio2")
      q.get(no_ack: true).try(&.body_io.to_s).should eq("prio1")
    end
  end

  it "should prioritize messages as 0 if no prio is set" do
    with_channel do |ch|
      q_args = AMQP::Client::Arguments.new({"x-max-priority" => 10})
      q = ch.queue("", args: q_args)
      q.publish "prio0"
      q.publish "prio1", props: AMQP::Client::Properties.new(priority: 1)
      q.publish "prio00"
      q.get(no_ack: true).try(&.body_io.to_s).should eq("prio1")
      q.get(no_ack: true).try(&.body_io.to_s).should eq("prio0")
      q.get(no_ack: true).try(&.body_io.to_s).should eq("prio00")
    end
  end

  it "should only accept int32 as priority" do
    with_channel do |ch|
      expect_raises(AMQP::Client::Channel::ClosedException, "PRECONDITION_FAILED") do
        q_args = AMQP::Client::Arguments.new({"x-max-priority" => "a"})
        ch.queue("", args: q_args)
      end
    end
  end

  it "should only accept priority >= 0" do
    with_channel do |ch|
      q_args = AMQP::Client::Arguments.new({"x-max-priority" => 0})
      ch.queue("", args: q_args)
      expect_raises(AMQP::Client::Channel::ClosedException, "PRECONDITION_FAILED") do
        q_args = AMQP::Client::Arguments.new({"x-max-priority" => -1})
        ch.queue("", args: q_args)
      end
    end
  end

  it "should only accept priority <= 255" do
    with_channel do |ch|
      q_args = AMQP::Client::Arguments.new({"x-max-priority" => 255})
      ch.queue("", args: q_args)
      expect_raises(AMQP::Client::Channel::ClosedException, "PRECONDITION_FAILED") do
        q_args = AMQP::Client::Arguments.new({"x-max-priority" => 256})
        ch.queue("", args: q_args)
      end
    end
  end

  context "after restart" do
    after_each do
      FileUtils.rm_rf("/tmp/lavinmq-spec-priority-queue")
    end

    it "can restore the priority queue" do
      server = LavinMQ::Server.new("/tmp/lavinmq-spec-priority-queue")
      begin
        tcp_server = TCPServer.new("::1", 0)
        port = tcp_server.local_address.port
        spawn server.listen(tcp_server)
        with_channel(port: port) do |ch|
          q = ch.queue("pq", args: AMQP::Client::Arguments.new({"x-max-priority": 9}))
          q.publish "m1"
          q.publish "m2", props: AMQP::Client::Properties.new(priority: 9)
          q.get(no_ack: false).try(&.body_io.to_s).should eq "m2"
          q.get(no_ack: false).try(&.body_io.to_s).should eq "m1"
        end
      ensure
        server.close
      end
      s2 = LavinMQ::Server.new("/tmp/lavinmq-spec-priority-queue")
      begin
        tcp_server = TCPServer.new("::1", 0)
        port = tcp_server.local_address.port
        spawn s2.listen(tcp_server)
        with_channel(port: port) do |ch|
          q = ch.queue("pq", args: AMQP::Client::Arguments.new({"x-max-priority": 9}))
          q.publish "m3", props: AMQP::Client::Properties.new(priority: 8)
          q.get(no_ack: false).try(&.body_io.to_s).should eq "m2"
          q.get(no_ack: false).try(&.body_io.to_s).should eq "m3"
          q.get(no_ack: false).try(&.body_io.to_s).should eq "m1"
        end
      ensure
        s2.close
      end
    end
  end
end
