require "socket"
require "./amqp"
require "./client"
require "./message"
require "./exchange"
require "./queue"

module AMQPServer
  class Server
    def initialize
      @state = State.new
    end

    def listen(port : Int)
      server = TCPServer.new("localhost", port)
      puts "Server listening on #{server.local_address}"
      loop do
        if socket = server.accept?
          spawn handle_connection(socket)
        else
          break
        end
      end
    end

    def handle_connection(socket)
      client = Client.new(socket, @state)
      client.run_loop
    end

    class State
      getter exchanges, queues

      def initialize
        @exchanges = {
          "amq.direct" => Exchange.new("amq.direct", type: "direct", durable: true, 
                                       bindings: { "rk" => [Queue.new("q1")] })
        }
        @queues = {
          "q1" => Queue.new("q1")
        }
      end
    end
  end
end
