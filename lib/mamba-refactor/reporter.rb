require 'directory_watcher'
require 'rbconfig'

module Mamba
	class Reporter
		attr_accessor    :numCasesRun
		attr_accessor    :currentTestCase
		attr_accessor    :watcher
		attr_accessor	 :topic_exchange

		# Initialize Reporter variables and create directory watcher instance
		# @param [Boolean] Signifies if the fuzzer using this reporter is distributed (Default: false)
		def initialize(distributed=false)
			@reporter_logger = init_logger() 
			@numCasesRun = 0
			@numCrashes = 0
			@currentTestCase = 0
			@startTime = Time.now()
			@crashes =  Hash.new()
			@watcher = DirectoryWatcher.new(os_crash_dir(), :pre_load => true)
			@watcher.interval = 2.0

			#
			# Check for distributed notification
			#
			if(distributed) then
				detectionFunction = "add_detected_crash_remote"
			else
				detectionFunction = "add_detected_crash"
			end

			#
			# Set the watching function
			#
			@watcher.add_observer do |*args|
				args.each do |event|
					#
					# Check for an added file
					#
					if(event[:type] == :added) then
						self.send(detectionFunction, event)
					end
				end
			end

			# Install the real time reporter signal handler
			Kernel.trap("INFO") do
				print_report(@reporter_logger)	
			end

			return(self)
		end

		# Adds a newly detected crash to the metrics
		# @param [Event] Information about a file system event
		def add_detected_crash(event)
			crash = Hash.new()
			crash['CrashReport'] = event[:path]
			crash['ProbTestCase'] = @currentTestCase
			crash['CrashTime'] = Time.now().strftime("%B %d, %Y - %I:%M:%S %p")

			#
			# Add it to the global crashes
			#
			@crashes[@currentTestCase] = crash
		end

		# Notify cluster of a detected crash 
		# @param [Event] Information about a file system event
		def add_detected_crash_remote(event)
			@topic_exchange.publish("#{event[:path]}+#{@currentTestCase}+#{Time.now()}", :key => "crashes")
		end

		# Handle remote notification of crashes from other nodes
		# @param [AMQP::Protocol::Header] Header of an amqp message
		# @param [String] Payload of an amqp message (Crash file information)
		def remote_notification(header, crashInfo)
			crashInfoArr = crashInfo.split("+")
			crash = Hash.new()
			crash['CrashReport'] = crashInfoArr[0] 
			crash['ProbTestCase'] = crashInfoArr[1] 
			crash['CrashTime'] = crashInfoArr[2] 

			#
			# Make sure test case not already recorded (helps running multiple instances on the same node)
			#
			if(!@crashes.has_key?(crashInfoArr[1])) then
				@crashes[crashInfoArr[1]] = crash 
			end
		end

		# Print information pertaining to run time, test cases run, and crashes
		# @param [Logger] A log4r instance to print logging information on runtime and crashes
		def print_report(logger)
			logger.info("==========================================================")
			logger.info("                       STATUS")
			logger.info("==========================================================")

			elapsedTime = Time.now() - @startTime
			logger.info("Start Time:                #{@startTime.strftime("%B %d, %Y (%A)- %I:%M:%S %p")}")
			logger.info("Elapsed Runtime:           #{elapsedTime} secs")
			logger.info("Number of Test Cases Run:  #{@numCasesRun} ")
			logger.info("Average Test Case Runtime: #{elapsedTime/@numCasesRun}")  
			logger.info("Number of Crashes Found:   #{@crashes.size()}")
			logger.info("Crashes:                   ")

			# Format the crash string
			@crashes.each do |key, crash|
				logger.info(crash['CrashReport'] + " : " + crash['CrashTime'] + " : " + crash['ProbTestCase'].to_s())
			end
			logger.info("==========================================================")
		end

		private

		# Determines the appropriate crash directory for the operating system
		# @return [String] Directoy to watch for crash logs
		def os_crash_dir()
			case RbConfig::CONFIG["host_os"]
			when /^darwin10\.\d+\.\d+$/
				return("/Users/#{ENV['USER']}/Library/Logs/DiagnosticReports")
			else
				raise "Error: Unsupported Operating System (#{RbConfig::CONFIG["host_os"]})"
			end
		end

        # @param [Type] Type of fuzzer, used to name the log file
        # @return [Logger] A logger created from the log4r library
        def init_logger()
            logfilename         = "logs/Reporter." + Time.now.strftime("%Y-%m-%d-%H-%M-%S") + ".log"
            logger              = Log4r::Logger.new('MambaFuzzer_Reporter')
            pattern             = Log4r::PatternFormatter.new(:pattern => "%d %l %m")
            logger.outputters   = Log4r::FileOutputter.new("mambareporterlogfile", :filename => logfilename, :formatter => pattern, :truncate => true)
            logger.level        = Log4r::ALL
            return(logger)
        end
	end
end
