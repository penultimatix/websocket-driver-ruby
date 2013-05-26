# encoding=utf-8

require "spec_helper"

describe WebSocket::Driver::Hybi do
  include EncodingHelper

  let :env do
    {
      "REQUEST_METHOD"                => "GET",
      "HTTP_CONNECTION"               => "Upgrade",
      "HTTP_UPGRADE"                  => "websocket",
      "HTTP_ORIGIN"                   => "http://www.example.com",
#      "HTTP_SEC_WEBSOCKET_EXTENSIONS" => "x-webkit-deflate-frame",
      "HTTP_SEC_WEBSOCKET_KEY"        => "JFBCWHksyIpXV+6Wlq/9pw==",
      "HTTP_SEC_WEBSOCKET_VERSION"    => "13"
    }
  end

  let :options do
    {:masking => false}
  end

  let :socket do
    socket = mock(WebSocket)
    socket.stub(:env).and_return(env)
    socket.stub(:write) { |message| @bytes = bytes(message) }
    socket
  end

  let :driver do
    driver = WebSocket::Driver::Hybi.new(socket, options)
    driver.on(:open)    { |e| @open = true }
    driver.on(:message) { |e| @message += e.data }
    driver.on(:error)   { |e| @error = e }
    driver.on(:close)   { |e| @close = [e.code, e.reason] }
    driver
  end

  before do
    @open = @error = @close = false
    @message = ""
  end

  describe "in the :connecting state" do
    it "starts in the :connecting state" do
      driver.state.should == :connecting
    end

    describe :start do
      it "writes the handshake response to the socket" do
        socket.should_receive(:write).with(
            "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Accept: JdiiuafpBKRqD7eol0y4vJDTsTs=\r\n" +
            "\r\n")
        driver.start
      end

      it "returns true" do
        driver.start.should == true
      end

      describe "with subprotocols" do
        before do
          env["HTTP_SEC_WEBSOCKET_PROTOCOL"] = "foo, bar, xmpp"
          options[:protocols] = ["xmpp"]
        end

        it "writes the handshake with Sec-WebSocket-Protocol" do
          socket.should_receive(:write).with(
              "HTTP/1.1 101 Switching Protocols\r\n" +
              "Upgrade: websocket\r\n" +
              "Connection: Upgrade\r\n" +
              "Sec-WebSocket-Accept: JdiiuafpBKRqD7eol0y4vJDTsTs=\r\n" +
              "Sec-WebSocket-Protocol: xmpp\r\n" +
              "\r\n")
          driver.start
        end

        it "sets the subprotocol" do
          driver.start
          driver.protocol.should == "xmpp"
        end
      end

      describe "with custom headers" do
        before do
          driver.set_header "Authorization", "Bearer WAT"
        end

        it "writes the handshake with custom headers" do
          socket.should_receive(:write).with(
              "HTTP/1.1 101 Switching Protocols\r\n" +
              "Upgrade: websocket\r\n" +
              "Connection: Upgrade\r\n" +
              "Sec-WebSocket-Accept: JdiiuafpBKRqD7eol0y4vJDTsTs=\r\n" +
              "Authorization: Bearer WAT\r\n" +
              "\r\n")
          driver.start
        end
      end

      it "triggers the onopen event" do
        driver.start
        @open.should == true
      end

      it "changes the state to :open" do
        driver.start
        driver.state.should == :open
      end

      it "sets the protocol version" do
        driver.start
        driver.version.should == "hybi-13"
      end
    end

    describe :frame do
      it "does not write to the socket" do
        socket.should_not_receive(:write)
        driver.frame("Hello, world")
      end

      it "returns true" do
        driver.frame("whatever").should == true
      end

      it "queues the frames until the handshake has been sent" do
        socket.should_receive(:write).with(
            "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Accept: JdiiuafpBKRqD7eol0y4vJDTsTs=\r\n" +
            "\r\n")
        socket.should_receive(:write).with(WebSocket::Driver.encode [0x81, 0x02, 72, 105])

        driver.frame("Hi")
        driver.start
      end
    end

    describe :ping do
      it "does not write to the socket" do
        socket.should_not_receive(:write)
        driver.ping
      end

      it "returns true" do
        driver.ping.should == true
      end

      it "queues the ping until the handshake has been sent" do
        socket.should_receive(:write).with(
            "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Accept: JdiiuafpBKRqD7eol0y4vJDTsTs=\r\n" +
            "\r\n")
        socket.should_receive(:write).with(WebSocket::Driver.encode [0x89, 0])

        driver.ping
        driver.start
      end
    end

    describe :close do
      it "does not write anything to the socket" do
        socket.should_not_receive(:write)
        driver.close
      end

      it "returns true" do
        driver.close.should == true
      end

      it "triggers the onclose event" do
        driver.close
        @close.should == [1000, ""]
      end

      it "changes the state to :closed" do
        driver.close
        driver.state.should == :closed
      end
    end
  end

  describe "in the :open state" do
    before { driver.start }

    describe :parse do
      let(:mask) { (1..4).map { rand 255 } }

      def mask_message(*bytes)
        output = []
        bytes.each_with_index do |byte, i|
          output[i] = byte ^ mask[i % 4]
        end
        output
      end

      it "parses unmasked text frames" do
        driver.parse [0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f]
        @message.should == "Hello"
      end

      it "parses multiple frames from the same packet" do
        driver.parse [0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f]
        @message.should == "HelloHello"
      end

      it "parses empty text frames" do
        driver.parse [0x81, 0x00]
        @message.should == ""
      end

      it "parses fragmented text frames" do
        driver.parse [0x01, 0x03, 0x48, 0x65, 0x6c]
        driver.parse [0x80, 0x02, 0x6c, 0x6f]
        @message.should == "Hello"
      end

      it "parses masked text frames" do
        driver.parse [0x81, 0x85] + mask + mask_message(0x48, 0x65, 0x6c, 0x6c, 0x6f)
        @message.should == "Hello"
      end

      it "parses masked empty text frames" do
        driver.parse [0x81, 0x80] + mask + mask_message()
        @message.should == ""
      end

      it "parses masked fragmented text frames" do
        driver.parse [0x01, 0x81] + mask + mask_message(0x48)
        driver.parse [0x80, 0x84] + mask + mask_message(0x65, 0x6c, 0x6c, 0x6f)
        @message.should == "Hello"
      end

      it "closes the socket if the frame has an unrecognized opcode" do
        driver.parse [0x83, 0x00]
        @bytes[0..3].should == [0x88, 0x1e, 0x03, 0xea]
        @error.message.should == "Unrecognized frame opcode: 3"
        @close.should == [1002, "Unrecognized frame opcode: 3"]
        driver.state.should == :closed
      end

      it "closes the socket if a close frame is received" do
        driver.parse [0x88, 0x07, 0x03, 0xe8, 0x48, 0x65, 0x6c, 0x6c, 0x6f]
        @bytes.should == [0x88, 0x07, 0x03, 0xe8, 0x48, 0x65, 0x6c, 0x6c, 0x6f]
        @close.should == [1000, "Hello"]
        driver.state.should == :closed
      end

      it "parses unmasked multibyte text frames" do
        driver.parse [0x81, 0x0b, 0x41, 0x70, 0x70, 0x6c, 0x65, 0x20, 0x3d, 0x20, 0xef, 0xa3, 0xbf]
        @message.should == encode("Apple = ")
      end

      it "parses frames received in several packets" do
        driver.parse [0x81, 0x0b, 0x41, 0x70, 0x70, 0x6c]
        driver.parse [0x65, 0x20, 0x3d, 0x20, 0xef, 0xa3, 0xbf]
        @message.should == encode("Apple = ")
      end

      it "parses fragmented multibyte text frames" do
        driver.parse [0x01, 0x0a, 0x41, 0x70, 0x70, 0x6c, 0x65, 0x20, 0x3d, 0x20, 0xef, 0xa3]
        driver.parse [0x80, 0x01, 0xbf]
        @message.should == encode("Apple = ")
      end

      it "parses masked multibyte text frames" do
        driver.parse [0x81, 0x8b] + mask + mask_message(0x41, 0x70, 0x70, 0x6c, 0x65, 0x20, 0x3d, 0x20, 0xef, 0xa3, 0xbf)
        @message.should == encode("Apple = ")
      end

      it "parses masked fragmented multibyte text frames" do
        driver.parse [0x01, 0x8a] + mask + mask_message(0x41, 0x70, 0x70, 0x6c, 0x65, 0x20, 0x3d, 0x20, 0xef, 0xa3)
        driver.parse [0x80, 0x81] + mask + mask_message(0xbf)
        @message.should == encode("Apple = ")
      end

      it "parses unmasked medium-length text frames" do
        driver.parse [0x81, 0x7e, 0x00, 0xc8] + [0x48, 0x65, 0x6c, 0x6c, 0x6f] * 40
        @message.should == "Hello" * 40
      end

      it "parses masked medium-length text frames" do
        driver.parse [0x81, 0xfe, 0x00, 0xc8] + mask + mask_message(*([0x48, 0x65, 0x6c, 0x6c, 0x6f] * 40))
        @message.should == "Hello" * 40
      end

      it "replies to pings with a pong" do
        driver.parse [0x89, 0x04, 0x4f, 0x48, 0x41, 0x49]
        @bytes.should == [0x8a, 0x04, 0x4f, 0x48, 0x41, 0x49]
      end
    end

    describe :frame do
      it "formats the given string as a WebSocket frame" do
        driver.frame "Hello"
        @bytes.should == [0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f]
      end

      it "formats a byte array as a binary WebSocket frame" do
        driver.frame [0x48, 0x65, 0x6c]
        @bytes.should == [0x82, 0x03, 0x48, 0x65, 0x6c]
      end

      it "encodes multibyte characters correctly" do
        message = encode "Apple = "
        driver.frame message
        @bytes.should == [0x81, 0x0b, 0x41, 0x70, 0x70, 0x6c, 0x65, 0x20, 0x3d, 0x20, 0xef, 0xa3, 0xbf]
      end

      it "encodes medium-length strings using extra length bytes" do
        message = "Hello" * 40
        driver.frame message
        @bytes.should == [0x81, 0x7e, 0x00, 0xc8] + [0x48, 0x65, 0x6c, 0x6c, 0x6f] * 40
      end

      it "encodes close frames with an error code" do
        driver.frame "Hello", :close, 1002
        @bytes.should == [0x88, 0x07, 0x03, 0xea, 0x48, 0x65, 0x6c, 0x6c, 0x6f]
      end

      it "encodes pong frames" do
        driver.frame "", :pong
        @bytes.should == [0x8a, 0x00]
      end
    end

    describe :ping do
      it "writes a ping frame to the socket" do
        driver.ping("mic check")
        @bytes.should == [0x89, 0x09, 0x6d, 0x69, 0x63, 0x20, 0x63, 0x68, 0x65, 0x63, 0x6b]
      end

      it "returns true" do
        driver.ping.should == true
      end

      it "runs the given callback on matching pong" do
        driver.ping("Hi") { @reply = true }
        driver.parse [0x8a, 0x02, 72, 105]
        @reply.should == true
      end

      it "does not run the callback on non-matching pong" do
        driver.ping("Hi") { @reply = true }
        driver.parse [0x8a, 0x03, 119, 97, 116]
        @reply.should == nil
      end
    end

    describe :close do
      it "writes a close frame to the socket" do
        driver.close("<%= reasons %>", 1003)
        @bytes.should == [0x88, 0x10, 0x03, 0xeb, 0x3c, 0x25, 0x3d, 0x20, 0x72, 0x65, 0x61, 0x73, 0x6f, 0x6e, 0x73, 0x20, 0x25, 0x3e]
      end

      it "returns true" do
        driver.close.should == true
      end

      it "does not trigger the onclose event" do
        driver.close
        @close.should == false
      end

      it "does not trigger the onerror event" do
        driver.close
        @error.should == false
      end

      it "changes the state to :closing" do
        driver.close
        driver.state.should == :closing
      end
    end
  end

  describe "when masking is required" do
    before do
      options[:require_masking] = true
      driver.start
    end

    it "does not emit a message" do
      driver.parse [0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f]
      @message.should == ""
    end

    it "returns an error" do
      driver.parse [0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f]
      @close.should == [1003, "Received unmasked frame but masking is required"]
    end
  end

  describe "in the :closing state" do
    before do
      driver.start
      driver.close
    end

    describe :frame do
      it "does not write to the socket" do
        socket.should_not_receive(:write)
        driver.frame("dropped")
      end

      it "returns false" do
        driver.frame("wut").should == false
      end
    end

    describe :ping do
      it "does not write to the socket" do
        socket.should_not_receive(:write)
        driver.ping
      end

      it "returns false" do
        driver.ping.should == false
      end
    end

    describe :close do
      it "does not write to the socket" do
        socket.should_not_receive(:write)
        driver.close
      end

      it "returns false" do
        driver.close.should == false
      end
    end

    describe "receiving a close frame" do
      before do
        driver.parse [0x88, 0x04, 0x03, 0xe9, 0x4f, 0x4b]
      end

      it "triggers the onclose event" do
        @close.should == [1001, "OK"]
      end

      it "changes the state to :closed" do
        driver.state.should == :closed
      end
    end
  end

  describe "in the :closed state" do
    before do
      driver.start
      driver.close
      driver.parse [0x88, 0x02, 0x03, 0xea]
    end

    describe :frame do
      it "does not write to the socket" do
        socket.should_not_receive(:write)
        driver.frame("dropped")
      end

      it "returns false" do
        driver.frame("wut").should == false
      end
    end

    describe :ping do
      it "does not write to the socket" do
        socket.should_not_receive(:write)
        driver.ping
      end

      it "returns false" do
        driver.ping.should == false
      end
    end

    describe :close do
      it "does not write to the socket" do
        socket.should_not_receive(:write)
        driver.close
      end

      it "returns false" do
        driver.close.should == false
      end

      it "leaves the state as :closed" do
        driver.close
        driver.state.should == :closed
      end
    end
  end
end

