#!/usr/bin/env ruby
# == Synopsis
# integrit-remote is a tool for using integrit on a remote filesystem.
# It uploads integrit (plus any attendant databases, if such exist) and runs
# integrit remotely. It then compares the remotely-generated databases against
# the local ones.

require 'net/smtp'
require 'optparse'
require 'rdoc/usage'
require 'ostruct'
require 'rubygems'
require 'rush'

class Integrit_Remote
  BASE_DIR        = Dir.pwd
  INTEGRIT_BINARY = BASE_DIR+'/bin/integrit'
  CONFIG_DIR      = BASE_DIR+'/config-files/'
  DATABASE_DIR    = BASE_DIR+'/databases/'
  VERSION         = '0.0.1'

  #
  # == Explosions!
  # This blows up. Awesome.
  def initialize(arguments, stdin)
    @arguments = arguments
    @stdin = stdin
    
    # Initialise rush
    @local = Rush::Box.new('localhost')
    @options = OpenStruct.new
    @options.init = false
    @options.update = false
    @options.outputList = true
  end
  
  def run
    # Parse options
    opts = OptionParser.new
    opts.banner = "Usage message here"
    opts.on('-i', '--init SITE', 'Initialise a new site') do |sitename|
      @options.init = sitename
      @options.outputList = false
      initSite
    end
    opts.on('-u', '--update SITE', 'Update an existing site\'s known-good db') do |sitename|
      @options.update = sitename
      @options.outputList = false
      updateSite
    end
    opts.on('-c', '--check SITE', 'Check an existing site\'s integrity') do |sitename|
      @options.check = sitename
      @options.outputList = false
      checkSite
    end
    
    
    opts.parse!(@arguments)
    
    if(@options.outputList) then
      output
    end
        
  end
  
  protected
  
    def initSite
      # Create config
      puts @options.init
    end
  
    def updateSite
      # Update known-good db 
      # Get the config file...
      config_filename = @options.update+".integrit.conf"
      config_file = @local[CONFIG_DIR+"/"+config_filename]
      host = remote_host config_file
      
      uploadBinaryAndConfig(config_file, config_filename, host)
  
      # Remote-execute
      begin
        if (@local.bash 'ssh '+host+' ./integrit -u -C '+config_filename) then
          # Execution was successful; grab the newly-generated cdb file and move to local
          local_filename_db = @options.update+".integrit.known.cdb"
          remote_filename_db = @options.update+".integrit.current.cdb"
          transfer host+":"+remote_filename_db, DATABASE_DIR+"/"+local_filename_db
        end
      rescue Rush::BashFailed => e
        puts "ERROR: #{e}"
      end
    end
  
    def checkSite
      # Update known-good db 
      # Get the config file...
      config_filename = @options.check+".integrit.conf"
      config_file = @local[CONFIG_DIR+"/"+config_filename]
      host = remote_host config_file
      
      uploadBinaryAndConfig(config_file, config_filename, host)
      
      known_db = @options.check+".integrit.known.cdb"
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
            Net::SMTP.start('mail.acidgreen.com.au', 25) do |smtp| 
                  smtp.send_message message+output, 'andy.white@acidgreen.com.au', 'andy.white@acidgreen.com.au'
            end
            
            # Update the known-good db so we don't spam the bejeesus out of support
            @options.update = @options.check
            updateSite
            
        end
      rescue Rush::BashFailed => e
        puts "ERROR: #{e}"  
      end
    end
    
    def uploadBinaryAndConfig(config_file_local, config_filename_remote, host)
      # Upload the binary and our config file to the remote host
      #TODO: Check that file exists and error correct if it doesn't
  
      # Upload the binary (in case it's been compromised on remote)
      transfer INTEGRIT_BINARY, host+":integrit"
  
      # Upload the config file
      transfer config_file_local.to_s, host+":"+config_filename_remote
    end
  
    def remote_host(config_file)
      # Now grab the ssh host string from the config file (expected format is '# Host: user@server')
      # NOTE: This utility expects that you have an ssh key set up for this connection
      return config_file.contents.match(/(# Host: )(.*)$/)[2]
    end
  
    def transfer(hostAndFile1, hostAndFile2)
      # Move a file via scp from one host to another
      begin
        if (@local.bash 'scp '+hostAndFile1+' '+hostAndFile2) == false then
          puts "ERROR: Upload FAILED (but for a legit reason?)"
          return false
        end
      rescue Rush::BashFailed => e
        puts "Error uploading file: #{e.message}"
      end
    end
  
    def output
      #Output list of sites
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