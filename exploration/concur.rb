#
# Exploration of possible semantics for parallel remote command execution,
#     implementation thereof, and models of the expected use cases.  
#
# Contents:
#
#  * Housekeeping & utilities (mostly ignore this)
#  * Use cases
#  * Solution Sketch
#  * Test runner


#############################################
## 
## Housekeeping & utilities
##
#############################################

require 'rubygems'
require 'net/ssh'
require 'ostruct'

class Doer < OpenStruct
  def initialize(options = {})
    super({:user => `whoami`.chomp,:options => {},:host => 'localhost',:stdout => '',:stderr => '', :stdin => ''}.update(options))
  end
  def result
    @result ||= OpenStruct.new(:stdout => stdout,:stderr => stderr)
  end
  def print_results
    print "#{name.upcase}:\n"
    print result.stdout.chomp,"\n" unless result.stdout.empty?
    print result.stderr.chomp,"\n" unless result.stderr.empty?
  end
  def p(*args)
#    Kernel.p [@name,args]
  end
  def mark(*args)
#    Kernel.p [@name,args]
  end
  def self.command_style
    :nested_blocks
  end
  def our_loop(ssh)
    i = 0
    i += 1 while ssh.process { ssh.busy? }
  end
  def self.wait_for_finish
    #  p :a
    #  ("p [:b,Thread.list.select { |t| t.alive? }.count]"; Thread.pass) while (Thread.list - [Thread.current]).any? { |t| t.alive? }
    #  p :c
    #  (Thread.list - [Thread.current]).each { |t| t.join }
    #  p :d
  end
  def ssh
    @ssh ||= Net::SSH.start(host, user, options)
  end
  def put_callbacks_on(x)
    x.on_data                   { |ch, data|       result.stdout << data }
    x.on_extended_data          { |ch, type, data| result.stderr << data if type == 1 }
    x.on_request("exit-status") { |ch, data|       result.exit_code = data.read_long  }
    x.send_data(stdin)
    x.eof!
  end
end

#############################################
## 
## Use cases
##
#############################################

Server = 'nc -l 1234'
Client = 'echo bar | nc localhost 1234' 
Use_cases = [
  {
    :hosts => [
    {
      :name => 'sam',
      :command => 'cat',
      :stdin => %q{
        Four score and seven commits ago, our developers brought forth on
        this repository a new version, concieved in haste, riddled with bugs,
        and dedicated to the proposition that if code fails in the network
        with no one to observe it it didn't really happen.
      }
    }
    ]
  },
  {
    :hosts => [
      {:name => 'sam', :command => Server},
      {:name => 'bob', :command => Client}
    ]
  },
#  {
#    :hosts => [
#      {:name => 'sam', :command => "sleep 0.5; #{Server}"}, 
#      {:name => 'bob', :command => Client}
#    ] 
#  },
  {
    :hosts => [
      {:name => 'sam', :command => Server}, 
      {:name => 'bob', :command => "sleep 0.5; #{Client}"}
    ]
  }
]


#############################################
## 
## Sketches of various possible solutions
##
#############################################

class D0 < Doer
  def do_remote(cmd)
    Net::SSH.start(host, user, options) { |ssh|
      ssh.open_channel { |channel|
        channel.exec(cmd) do |ch, success|
          abort "FAILED: couldn't execute command (ssh.channel.exec failure)" unless success
          yield if block_given?
        end
        put_callbacks_on(channel)
      }
      our_loop(ssh)
    }
  end
end

class D1 < Doer
  def do_remote(command)
    ssh.open_channel { |channel|
      channel.exec(command) { |terminal, success|
        abort "FAILED: to execute command on a new channel on #{@name}" unless success
        put_callbacks_on(terminal)
        yield if block_given?
      }
    }
    our_loop(ssh)
  end
end

class D2 < Doer
  def do_remote(command)
    ssh.open_channel { |channel|
      put_callbacks_on(channel)
      channel.exec(command) { |terminal, success|
        abort "FAILED: to execute command on a new channel on #{@name}" unless success
        yield if block_given?
      }
    }
    our_loop(ssh)
  end
end

class D3 < Doer
  def self.command_style
    :flat
  end
  attr :thread
  @@threads = []
  def initialize(*args)
    super(*args)
  end
  def do_remote(command)
    thread = Thread.new {
      ssh.open_channel { |ch|
        put_callbacks_on(ch)
        ch.exec(command) { |terminal, success|
          abort "FAILED: to execute command on a new channel on #{@name}" unless success
          Thread.current[:cmd_lanched] = true
        }
      }
      our_loop(ssh)
      Thread.current[:done] = true
    }
    Thread.pass until thread[:cmd_lanched]
    @@threads << thread
  end
  def self.wait_for_finish
    Thread.pass until @@threads.all? { |t| t[:done] }
  end
end

class D4 < Doer
  def self.command_style
    :flat
  end
  attr :thread
  @@threads = []
  def initialize(*args)
    super(*args)
  end
  def do_remote(command)
    thread = Thread.new {
      ssh.open_channel { |ch|
        ch.exec(command) { |terminal, success|
          abort "FAILED: to execute command on a new channel on #{@name}" unless success
          put_callbacks_on(terminal)
          Thread.current[:cmd_lanched] = true
        }
      }
      our_loop(ssh)
      Thread.current[:done] = true
    }
    Thread.pass until thread[:cmd_lanched]
    @@threads << thread
  end
  def self.wait_for_finish
    Thread.pass until @@threads.all? { |t| t[:done] }
  end
end

#############################################
## 
## Test runner
##
#############################################
reps =100
last = nil
Use_cases.each { |task|
  hosts = task[:hosts]
  print "="*70,"\n"
  hosts.each { |h| print "#{h[:name].upcase}: #{h[:command]}\n" }
  print "="*70,"\n"
  failures = Hash.new(0)
  i = 0
  ([D0]*reps+[D1]*reps+[D2]*reps+[D3]*reps+[D4]*reps).each { |d_class|
    (i = 0; puts) if d_class != last
    print "\r#{d_class}:#{i+=1}: #{failures.inspect}   "
    $stdout.flush
    last = d_class
    begin
#      print "-"*20,d_class.name," (#{d_class.command_style})","-"*20,"\n"
      hosts.each { |h| h[:obj] = d_class.new(h) }
      case d_class.command_style
        when :nested_blocks
          case hosts.length
            when 1: hosts[0][:obj].do_remote(hosts[0][:command])
            when 2:
              hosts[0][:obj].do_remote(hosts[0][:command]) { hosts[1][:obj].do_remote(hosts[1][:command]) }
            else fail
            end
        when :flat
          hosts.each { |h| h[:obj].do_remote(h[:command]) }
        else
          abort "Unknown command style: #{d_class.command_style} for #{d_class.name}"
        end
      d_class.wait_for_finish
    rescue Object => e
      puts e
      raise if e.is_a? Interrupt
    ensure
#      hosts.each { |h| h[:obj].print_results }
      failures[d_class] += 1 unless task == Use_cases[0] || hosts[0][:obj].result.stdout =~ /bar/
    end
  }
  p failures
#  print "Press RETURN"
#  readline
}
