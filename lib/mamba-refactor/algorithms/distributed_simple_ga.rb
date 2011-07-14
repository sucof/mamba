module Mamba
	module Algorithms
		class DistributedSimpleGeneticAlgorithm < SimpleGeneticAlgorithm 

			# Function to run the fuzzing 
			def fuzz()
				AMQP.start(:host => @amqpServer) do |connection|
					initialize_queues(connection)

					if(@organizer) then
						seed do |testCaseNumber|
							seed_distributed(testCaseNumber)
						end
					end
				end
			end


			# Function to handle results sent out by drones
			# @param [AMQP::Protocol::Header] Header of an amqp message
			# @param [String] Payload of an amqp message (test case results)
			def results(header, payload)
				chromosomeInfo = payload.split(".")
				@logger.info("Chromosome[#{chromosomeInfo[1]}]: #{chromosomeInfo[2]}")
				@reporter.numCasesRun = @reporter.numCasesRun + 1

				if(@organizer)
					@population.push(Chromosome.new(chromosomeInfo[1].to_i(), chromosomeInfo[2]))

					#
					# Check for condition to stop and condition to stop and evolve
					#
					if(@population.size == @simpleGAConfig['Population Size']) then
						@logger.info(@population.inspect())
						statistics()

						@nextGenerationNumber = @nextGenerationNumber + 1
						unless (@nextGenerationNumber) == @simpleGAConfig['Maximum Generations'] then
							evolve() 
							@testSetMappings.each_key do |key|
								seed_distributed(key)
							end
						else
							@topic_exchange.publish("shutdown", :key => "commands")
						end
					end
				end
			end

			# Function to run test cases received from the organizer
			# Note test case encoding is 1.0, where 1 is the generation, . a delimiter, and 0 population member number
			# @param [AMQP::Protocol::Header] Header of an amqp message
			# @param [String] Payload of an amqp message (test case to run)
			def testcases(header, testCaseID)

				remoteFD = @storage.dbHandle.get(testCaseID)
				testCaseFilename = "tests#{File::SEPARATOR}#{remoteFD.filename}"
				@logger.info("Got this for the remote test case filename: #{remoteFD.filename}")

				#
				# Optimization (Organizer already has all the files)
				#
				if(!@organizer) then
					localFD = File.open(testCaseFilename, "w+b")
					localFD.write(remoteFD.read())
					localFD.close()
				end

				@executor.run(@logger, testCaseFilename)

				# 
				# Store the results in the "cloud" :)
				#
				#			@storage.dbHandle.put(File.open(newTestCaseFilename), :_id => "0:#{testCaseNumber}", :filename => newTestCaseFilename)

				#
				# Cleanup remotes
				#
				if(!@organizer) then
					FileUtils.rm(testCaseFilename)
				end

				#			FileUtils.rm(testCaseFilename + ".xml")

				#
				# Post test case results 0.1.2
				#
				@topic_exchange.publish(testCaseID + "." + rand(25).to_s(), :key => "results")

				# Acknowledge the test case is done
				header.ack()	
			end

			private

			# Function to handle seeding mongodb and rabbitmq for distributed genetic algorithm
			# testCaseID Format: generationNumber.testcasenumber (e.g. 1.4 - means generation 1, chromosome 4)
			# testCaseFilename format: generationNumber.testcasefilename (e.g. 2.4.pdf - means generation 2 chromomse 4 with filename 4.pdf)
			# @param [Fixnum] The test case number
			def seed_distributed(testCaseNumber)
				testCaseID = @nextGenerationNumber.to_s() + "." + testCaseNumber.to_s()
				remoteTestCaseFilename = @testSetMappings[testCaseNumber].split(File::SEPARATOR)[-1]
				@storage.dbHandle.put(File.open(@testSetMappings[testCaseNumber]), :_id => testCaseID, :filename => remoteTestCaseFilename)
				@direct_exchange.publish(testCaseID, :routing_key => @queue.name)
			end
		end
	end
end
