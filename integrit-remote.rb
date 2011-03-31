#!/usr/bin/env ruby
# == Synopsis
# integrit-remote is a tool for using integrit on a remote filesystem.
# It uploads and runs integrit remotely.
# It then compares the remotely-generated databases against
# the local ones, and sends an email if changes are detected.

require 'net/smtp'
require 'optparse'
require 'rdoc/usage'
require 'ostruct'
require 'rubygems'
require 'rush'

class Integrit_Remote
  BASE_DIR = Dir.pwd
  INTEGRIT_BINARY = BASE_DIR+'/bin/integrit'
  CONFIG_DIR = BASE_DIR+'/config-files/'
  DATABASE_DIR = BASE_DIR+'/databases/'
  VERSION = '0.0.1'

  #
  # == Initialize
  # Set various defaults and options.
  def initialize(arguments, stdin)
    @arguments = arguments
    @stdin = stdin

    # Initialise rush
    @local = Rush::Box.new('localhost')
    @options = {}
    @options[:init] = false
    @options[:update] = false
    @options[:outputList] = true
    @options[:mailserver] = nil
    @options[:from_address] = "integrit@test.com" # test.com is an RFC'd black hole
    @options[:to_address] = nil
  end

  def run
    # Parse options
    opts = OptionParser.new
    opts.banner = "Usage: integrit-remote.rb [--init|--update|--check] sitename"

    #The mailserver MUST be specified
    opts.on('-m', '--mailserver', 'Specify the mailserver') do |mailserver|
      @options[:mailserver] = mailserver
    end

    opts.on('-f', '--from', 'Specify the from-address of the email') do |from_address|
      @options[:from_address] = from_address
    end

    opts.on('-t', '--to', 'Specify the to address of the email') do |to_address|
      @options[:to_address] = to_address
    end

    opts.on('-i', '--init SITE', 'Create the first known-good database for a site') do |sitename|
      @options[:init] = sitename
      @options[:outputList] = false
      init_site
    end

    opts.on('-u', '--update SITE', 'Update an existing site\'s known-good db') do |sitename|
      @options[:update] = sitename
      @options[:outputList] = false
      update_site
    end

    opts.on('-c', '--check SITE', 'Check an existing site\'s integrity') do |sitename|
      @options[:check] = sitename
      @options[:outputList] = false
      check_site
    end

    opts.parse!(@arguments)

    output if (@options[:outputList])

  end

  protected

  def init_site
    # Create config
    puts @options.init
  end

  # Update known-good db
  # Get the config file...
  def update_site
    config_filename = @options[:update]+".integrit.conf"
    config_file = @local[CONFIG_DIR+"/"+config_filename]
    host = remote_host config_file

    upload_binary_and_config(config_file, config_filename, host)

    # Remote-execute
    begin
      if (@local.bash 'ssh '+host+' ./integrit -u -C '+config_filename) then
        # Execution was successful; grab the newly-generated cdb file and move to local
        local_filename_db = @options[:update]+".integrit.known.cdb"
        remote_filename_db = @options[:update]+".integrit.current.cdb"
        transfer host+":"+remote_filename_db, DATABASE_DIR+"/"+local_filename_db
      end
    rescue Rush::BashFailed => e
      puts "ERROR: #{e}"
    end
  end

  def check_site
    # Update known-good db
    # Get the config file...

    # TODO: Freak out if the mailserver isn't supplied
    # TODO: Freak out if the to_address isn't specified
    # TODO: Pull email template from a file
    config_filename = @options[:check]+".integrit.conf"
    config_file = @local[CONFIG_DIR+"/"+config_filename]
    host = remote_host config_file

    upload_binary_and_config(config_file, config_filename, host)

    known_db = @options[:check]+".integrit.known.cdb"
    transfer DATABASE_DIR+"/"+known_db, host+":"+known_db

    begin
      output = @local.bash 'ssh '+host+' ./integrit -c -C '+config_filename
      puts output
      if output.match(/^(changed: |new: |deleted: )/) then
        # SEND EMAIL NAO
        message = <<MESSAGE_END
From: AcidGreen File Integrity Checker <support@acidgreen.com.au>
To: Support <support@acidgreen.com.au>
Subject: Changes detected on #{host}

This is a message from the AcidGreen file integrity checker.
This service has detected changes on a site that it monitors.
Such changes may be indicative of malicious activity.

Following is a list of the changes detected:


MESSAGE_END
          Net::SMTP.start(@options[:mailserver], 25) do | smtp |
          smtp.send_message message+output, @options[:from_address], @options[:to_address]
          smtp.finish
        end

        # Update the known-good db so we don't spam the bejeesus out of support
        @options.update = @options.check
        update_site

      end
    rescue Rush::BashFailed => e
      puts "ERROR: #{e}"
    end
  end

  # Upload the binary and our config file to the remote host
  #TODO: Check that file exists and error correct if it doesn't
  def upload_binary_and_config(config_file_local, config_filename_remote, host)

    # Upload the binary (in case it's been compromised on remote)
    transfer INTEGRIT_BINARY, host+":integrit"

    # Upload the config file
    transfer config_file_local.to_s, host+":"+config_filename_remote
  end

  # Grab the ssh host string from the config file (expected format is '# Host: user@server')
  # NOTE: This utility expects that you have an ssh key set up for this connection
  def remote_host(config_file)
    config_file.contents.match(/(# Host: )(.*)$/)[2]
  end

  # Move a file via scp from one host to another
  def transfer(host_and_file1, host_and_file2)
    begin
      if (@local.bash 'scp '+host_and_file1+' '+host_and_file2) == false then
        puts "ERROR: Upload FAILED (but for a legit reason?)"
        return false
      end
    rescue Rush::BashFailed => e
      puts "Error uploading file: #{e.message}"
    end
  end

  #Output list of sites
  def output
    puts "Config files exist for the following sites:"
    @local[CONFIG_DIR].contents.each do |file|
      puts "\t"+file.name.split('.')[0..-3].to_s+"\t"+file.last_modified.to_s
    end

    # And output our help file, too!
    RDoc::usage('synopsis')
  end

end

app = Integrit_Remote.new(ARGV, STDIN)
app.run()