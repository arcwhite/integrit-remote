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
require 'erb'

class Integrit_Remote
  BASE_DIR = Dir.pwd
  INTEGRIT_BINARY = BASE_DIR+'/bin/integrit'
  CONFIG_DIR = BASE_DIR+'/config-files/'
  DATABASE_DIR = BASE_DIR+'/databases/'
  VERSION = '0.0.1'

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
    @options[:email_template] = "template.erb"
  end

  def run

    if parse_options?
      exit unless arguments_valid? {|e| puts e}

      check_site  if @options[:check]
      update_site if @options[:update]
      init_site   if @options[:init]
    end
    output if (@options[:outputList])

  end

  protected

  def parse_options?
    opts = OptionParser.new
    opts.banner = "Usage: integrit-remote.rb [--init|--update|--check] site_name"

    #The mailserver MUST be specified
    opts.on('-m', '--mailserver smtp.mail.com', 'Specify the mailserver') do |mail_server|
      @options[:mailserver] = mail_server
    end

    opts.on('-f', '--from integrit@you.com', 'Specify the from-address of the email') do |from_address|
      @options[:from_address] = from_address
    end

    opts.on('-t', '--to user@example.com', 'Specify the to address of the email') do |to_address|
      @options[:to_address] = to_address
    end

    opts.on('-i', '--init SITE', 'Create the first known-good database for a site') do |site_name|
      @options[:init]       = true
      @options[:sitename]   = site_name
      @options[:outputList] = false
    end

    opts.on('-u', '--update SITE', 'Update an existing site\'s known-good db') do |site_name|
      @options[:update]     = true
      @options[:sitename]   = site_name
      @options[:outputList] = false
    end

    opts.on('-c', '--check SITE', 'Check an existing site\'s integrity') do |site_name|
      @options[:check]      = true
      @options[:sitename]   = site_name
      @options[:outputList] = false
    end

    opts.parse!(@arguments)
  end

  def arguments_valid?
    if @options[:check] && @options[:mailserver].nil?
      yield "You must specify a mailserver."
      return false
    end

    if @options[:check] && @options[:to_address].nil?
      yield "You must specify a to: address."
      return false
    end

    if @options[:sitename] && config_file.contents_or_blank.eql?("")
      yield "Invalid config file."
      return false
    end

    if get_mail_template(@options[:email_template]).contents_or_blank.eql?("")
      yield "Invalid email template file"
      return false
    end
    true
  end

  def config_filename
    CONFIG_DIR+"/"+@options[:sitename]+".integrit.conf"
  end

  def config_file
    @local[config_filename]
  end

  def get_mail_template(filename)
    @local[BASE_DIR+"/"+filename]
  end

  def email_template(filename)
    template = ERB.new get_mail_template(filename).contents
    template.result(binding)
  end

  def init_site
    # Create config
    # TODO: Implement
    puts @options[:init]
  end

  # Update known-good db
  def update_site
    host = remote_host config_file

    upload_binary_and_config config_file, config_filename, host

    # Remote-execute
    begin
      if (@local.bash 'ssh '+host+' ./integrit -u -C '+config_filename) then
        # Execution was successful; grab the newly-generated cdb file and move to local
        local_filename_db   = @options[:update]+".integrit.known.cdb"
        remote_filename_db  = @options[:update]+".integrit.current.cdb"
        transfer host+":"+remote_filename_db, DATABASE_DIR+"/"+local_filename_db
      end
    rescue Rush::BashFailed => e
      puts "ERROR: #{e}"
    end
  end

  def check_site
    # Update known-good db
    # Get the config file...

    @host = remote_host config_file

    upload_binary_and_config(config_file, config_filename, @host)

    known_db = @options[:check]+".integrit.known.cdb"
    transfer DATABASE_DIR+"/"+known_db, @host+":"+known_db

    begin
      output = @local.bash 'ssh '+@host+' ./integrit -c -C '+config_filename
      puts output
      if output.match(/^(changed: |new: |deleted: )/) then
        @changes = output
        message = email_template(@options[:email_template])
        puts message
        exit
        Net::SMTP.start(@options[:mailserver], 25) do | smtp |
        smtp.send_message message+output, @options[:from_address], @options[:to_address]
        smtp.finish
      end

      # Update the known-good db so we don't spam the bejeesus out of support
      update_site

      end
    rescue Rush::BashFailed => e
      puts "ERROR: #{e}"
    end
  end

  # Upload the binary (in case it's been compromised on remote) and our config file to the remote host
  def upload_binary_and_config(config_file_local, config_filename_remote, host)
    transfer INTEGRIT_BINARY, host+":integrit"
    transfer config_file_local.to_s, host+":"+config_filename_remote
  end

  # Grab the ssh host string from the config file (expected format is '# Host: user@server')
  # NOTE: This utility expects that you have an ssh key set up for this connection
  def remote_host(the_file)
    the_file.contents.match(/(# Host: )(.*)$/)[2]
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

  # Output list of sites
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

