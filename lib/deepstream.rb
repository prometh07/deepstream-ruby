# coding: utf-8

# Copyright (c) 2015, Currency-One S.A.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#     http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


require 'socket'
require 'json'
require 'timeout'


module Deepstream end


class Deepstream::Record

  def initialize(client, name, data, version)
    @client, @name, @data, @version = client, name, data, version
  end

  def set(*args)
    if args.size == 1
      @client._write('R', 'U', @name, (@version += 1), JSON.dump(args[0]))
      @data = OpenStruct.new(args[0])
    else
      @client._write('R', 'P', @name, (@version += 1), args[0][0..-2], @client._typed(args[1]))
    end
  end

  def _patch(version, field, value)
    @version = version.to_i
    @data[field] = value
  end

  def _update(version, data)
    @version = version.to_i
    @data = data
  end

  def method_missing(name, *args)
    set(name, *args) if name[-1] == '='
    @data.send(name, *args)
  end

end


class Deepstream::Client

  def initialize(address, port = 6021)
    @address, @port, @unread_msg, @event_callbacks, @records = address, port, nil, {}, {}
  end

  def emit(event, value = nil)
    _write('E', 'EVT', event, _typed(value))
  end

  def on(event, &block)
    _write_and_read('E', 'S', event)
    @event_callbacks[event] = block
  end

  def get(record_name)
    _write_and_read('R', 'CR', record_name)
    msg = _read
    @records[record_name] = Deepstream::Record.new(self, record_name, _parse_data(msg[4]), msg[3].to_i)
  end

  def _open_socket
    timeout(2) { @socket = TCPSocket.new(@address, @port) }
    Thread.start do
      loop { _process_msg(@socket.gets(30.chr).tap { |m| break m.chomp(30.chr).split(31.chr) if m }) }
    end
  rescue
    print Time.now.to_s[/.+ .+ /], "Can't connect to deepstream server\n"
    raise
  end

  def _connect
    _open_socket
    @connected = true
    @connected = _write_and_read(%w{A REQ {}}) { |msg| msg == %w{A A} }
  end

  def _write_and_read(*args)
    @unread_msg = nil
    _write(*args)
    yield _read if block_given?
  end

  def _write(*args)
    _connect unless @connected
    @socket.write(args.join(31.chr) + 30.chr)
  rescue
    @connected = false
  end

  def _process_msg(msg)
    case msg[0..1]
    when %w{E EVT} then _fire_event_callback(msg)
    when %w{R P} then @records[msg[2]]._patch(msg[3], msg[4], _parse_data(msg[5]))
    when %w{R U} then @records[msg[2]]._update(msg[3], _parse_data(msg[4]))
    else @unread_msg = msg
    end
  end

  def _read
    loop { break @unread_msg || (next sleep 0.01) }.tap { @unread_msg = nil }
  end

  def _fire_event_callback(msg)
    @event_callbacks[msg[2]].tap { |cb| cb.(_parse_data(msg[3])) if cb }
  end

  def _typed(value)
    case value
    when Hash then "O#{value.to_json}"
    when String then "S#{value}"
    when Numeric then "N#{value}"
    when TrueClass then 'T'
    when FalseClass then 'F'
    when NilClass then 'L'
    end
  end

  def _parse_data(payload)
    case payload[0]
    when 'O' then JSON.parse(payload[1..-1], object_class: OpenStruct)
    when '{' then JSON.parse(payload, object_class: OpenStruct)
    when 'S' then payload[1..-1]
    when 'N' then payload[1..-1].to_f
    when 'T' then true
    when 'F' then false
    when 'L' then nil
    end
  end

end