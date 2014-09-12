
if ::FFI::Platform.windows?
  begin
    require 'win32/process'
  rescue LoadError
    puts "Warning: The win32-process gem is required for PID file use on Windows. Install the gem (in your Gemfile if using bundler) to avoid errors."
  end
end

module SpiderGazelle
  class PidFileExists < RuntimeError; end

  module Management
    class Pid
      def initialize(path)
        @pid_file = path

        remove_stale_pid_file
        write_pid_file

        # At application exit remove the file
        #  unless of course we do not own the file
        cur = ::Process.pid
        at_exit do
          if cur == current
            remove_pid_file
          end
        end
      end
      
      def current
        File.exist?(@pid_file) ? open(@pid_file).read.to_i : nil
      end

      def running?(pid)
        if ::FFI::Platform.windows?
          begin
            # Returns exit code or nil if still running
            if ::Process.respond_to? :get_exitcode
              return ::Process.get_exitcode(pid).nil?
            else
              # win32/process not loaded
              return false
            end
          rescue
            # PID probably doesn't exist
            false
          end
        else
          begin
            ::Process.getpgid(pid) != -1
          rescue ::Errno::EPERM
            # Operation not permitted
            true
          rescue ::Errno::ESRCH
            # No such process
            false
          end
        end
      end

      protected


      def remove_stale_pid_file
        if File.exist?(@pid_file)
          pid = current

          if pid && running?(pid)
            raise PidFileExists, "#{@pid_file} already exists, seems like it's already running (process ID: #{pid}). " +
                                 "Stop the process or delete #{@pid_file}."
          else
            remove_pid_file
          end
        end
      end

      def write_pid_file
        File.open(@pid_file, 'w') do |f|
          f.write ::Process.pid
        end
        File.chmod(0644, @pid_file)
      end

      def remove_pid_file
        File.delete(@pid_file) if @pid_file && File.exists?(@pid_file)
      end
    end
  end
end
