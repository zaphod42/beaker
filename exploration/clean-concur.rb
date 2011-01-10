require 'rubygems'
require 'net/ssh'
require 'net/ssh/multi'
require 'ostruct'

Server = 'nc -l 1234'
Client = 'echo bar | nc localhost 1234'
Tests = [
         [{:name => 'sam', :command => 'cat', :stdin => 'x' * 65539 }],
         [{:name => 'sam', :command => 'cat', :stdin => 'x' * 65539 },
          {:name => 'max', :command => 'cat', :stdin => 'x' * 65539 }],
         [{:name => 'sam', :command => Server},
          {:name => 'max', :command => Client}],
         # more go here...
        ]

Tests.each do |tests|
  Net::SSH::Multi.start do |session|
    puts "=" * 72
    puts "Starting a test now..."
    tests.each do |test|
      test[:ssh] ||= session.use "#{`whoami`.chomp}@localhost"

      channel = session.on(test[:ssh]).exec(test[:command]) do |ch, stream, data|
        puts "[#{test[:name]} : #{stream}] #{data.length} bytes/chars received"
      end

      test[:stdin] and channel.send_data(test[:stdin])
      channel.eof!
    end

    # ...and loop, baby.
    puts "starting the SSH session loop now..."
    session.loop
  end
end
