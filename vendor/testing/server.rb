require "sinatra/base"
require "erubis"
require "ostruct"
require "listen"
require "pathname"
require "json"
require "sinatra/json"

class Array 
  def files(ext) 
    self.find_all do |name|
      name.include?(ext)
    end
  end
end

# ---- wrap to html attribute or return content 

module FileHelpers
  def to_css(name) 
    "<link rel='stylesheet' type='text/css' href='#{name}'>"
  end

  def to_js(name)
    "<script type='text/javascript' src='#{name}'></script>"
  end

  def to_html(name)
    File.open("#{name}", "rb").read
  end
end

# ------- browser and platform helpers ---------

module BrowsersHelpers 

  #original http://stackoverflow.com/a/171011/1581531
  module OS
    extend self 
    def windows?
      (/cygwin|mswin|mingw|bccwin|wince|emx/ =~ RUBY_PLATFORM) != nil
    end

    def mac?
     (/darwin/ =~ RUBY_PLATFORM) != nil
    end

    def unix?
      !windows?
    end

    def linux?
      unix? and not mac?
    end
  end

  class << self 
    include OS
    def phantom?
      !!system('phantomjs -v')
    end

    def get_browsers
      `apropos browser`
    end

    def browsers 
      tmp = ["Firefox", "Chrome", "Chromium", "Opera"]
      
      #FIXME: windows version
      tmp = tmp + (6..11).inject([]){|a, v| a << ["IE#{v}"] }.flatten if windows? 
      tmp << "Safari"  if mac?          

      #FIXME the same for windows
      tmp.delete_if do |b|
        !get_browsers.include?(b.downcase)    
      end if linux? || mac?

      tmp << "PhantomJS" if phantom?
      arr = []
      tmp.each do |b|
        arr << [b, %x{"#{b.downcase}" --version}.strip]
      end
      arr 
    end 
  end    
end

#-------- module Tests ---------
# provides methods for manipulate sources  
# 
module Tests
  extend self
  extend FileHelpers
  
  BASE_DIR      = Dir.pwd  # prototype lib
  TEST_DIR      = "#{BASE_DIR}/test/unit" # old tests
  FIXTURES_DIR  = "#{BASE_DIR}/test/unit/fixtures" 
  PUBLIC_DIR    = "#{BASE_DIR}/vendor/testing/public" 
  OUTPUT_DIR    = "#{PUBLIC_DIR}/tests" # compile tests to this dir 
  TEST_FILES    = Dir["#{TEST_DIR}/*.js"] # all tests files
  TEMPLATE_FILE = "#{BASE_DIR}/vendor/testing/views/template.erb" # base template
  FIXTURES      = Dir["#{FIXTURES_DIR}/*"] # fixtures for tests
  TMP           = "#{OUTPUT_DIR}/tmp" 
  PROTOTYPE_DIR = "#{BASE_DIR}/src" 

  # build prototypejs from source and generate tests files
  def build!
    FileUtils.mkdir_p(Tests::OUTPUT_DIR)
    FileUtils.mkdir_p(Tests::TMP)

    puts "=== build prototype.js"
    system("rake dist")
    
    TEST_FILES.each do |file|
      Tests::generate_test(file)
    end

    FileUtils.cp("#{BASE_DIR}/dist/prototype.js", "#{PUBLIC_DIR}")
  end

  # directory observer, need observe src/ and test/unit/ directory 
  def start 
    base = "#{Tests::BASE_DIR}"
    @@listener = Listen.to("#{base}/src", "#{base}/test/unit", only: /\.(js|css|html)$/) do |modified, added, removed|
      if !modified.empty?
        modified.each do |file|
          name = File.basename(file)
            
          puts "=== modified #{name}"

          arr = []
          Pathname.new(file).descend{|d| arr << d.to_s }

          if arr.include?(PROTOTYPE_DIR)
            
            puts "=== change in source. rebuild all."
            
            build!
          elsif arr.include?(FIXTURES_DIR) || arr.include?(TEST_DIR)
            name_without_ext = File.basename(file, ".*").sub("_test", "")
            
            puts "=== changes in #{name_without_ext.capitalize} tests"
            
            FileUtils.rm("#{OUTPUT_DIR}/test_#{name_without_ext}.html")
            Dir["#{OUTPUT_DIR}/tmp/#{name_without_ext}.*"].each do |f|
              FileUtils.rm(f)
            end

            puts "=== regenerate test..."
            
            Dir["#{TEST_DIR}/#{name_without_ext}_test.js"].each do |f|
              generate_test(file)
            end
          end
        end
      end
  
      if !added.empty?
        FileUtils.rm_rf(OUTPUT_DIR)
        added.each do |file|
          name = File.basename(name)
          puts "=== add #{name}"
          puts "=== rebuild all"
          build!
        end
      end

      if !removed.empty?
        FileUtils.rm_rf(OUTPUT_DIR)
        removed.each do |file|
          name = File.basename(name)
          puts "=== removed #{name}"
          puts "=== rebuild all"
          build!
        end
      end

    end.start
  end

  # on stop remove directory with tests
  def stop
    @@listener.terminate
    FileUtils.rm_rf(OUTPUT_DIR)
  end


  # compile tests 
  def generate_test(file) 
    file_name = File.basename(file, ".js").split("_").first
    file_fixtures = FIXTURES.find_all do |fx| 
      File.basename(fx).include?(file_name)
    end  
    
    context = Erubis::Context.new()

    css = file_fixtures.files(".css")
    js = file_fixtures.files(".js")
    logo = file_fixtures.files(".gif")
    html = file_fixtures.files(".html")
    
    mv_to_tmp(css)
    mv_to_tmp(js)
    mv_to_tmp(logo) 
    
    test_file = "#{file_name}_test"
    
    File.open("#{TMP}/#{test_file}.js", "w") do |f|
      f.write(File.open(file).read)
    end

    test_file = to_js("tmp/#{test_file}.js")

    context[:css]  = css.map{|f| to_css("tmp/#{File.basename(f)}")}.join 
    context[:html] = html.map{|f| to_html(f)}.join
    context[:js]   = js.map{|f| to_js("tmp/#{File.basename(f)}")}.join
    context[:logo] = logo.map{|f| to_js("tmp/#{File.basename(f)}")}.join
    context[:test_file] = test_file
    context[:title] = "#{file_name.capitalize} test"

    puts "=== generate #{file_name} test"

    input = File.read("#{TEMPLATE_FILE}")
    eruby = Erubis::Eruby.new(input)
    File.open("#{OUTPUT_DIR}/test_#{file_name}.html", "w") do |f|
      f.write(eruby.evaluate(context))
    end
  end

  
  def mv_to_tmp(arr) 
    arr.each do |file|
      name = File.basename(file)
      File.open("#{TMP}/#{name}", "w") do |f|
        f.write(File.open(file).read)
      end
    end
  end

  private :mv_to_tmp
   
  
end


# ------------------ base app ----------------------

class MyApp < Sinatra::Base
   
  configure do
    puts "=== start server..."
    puts "=== generate test files..."

    Tests::build!

    puts "=== start observe..."
    
    Tests::start 
  end

  get '/' do
    @browsers = BrowsersHelpers::browsers
    @files = Tests::TEST_FILES.map do |file|
      tmp = File.basename(file, ".js").split("_")
      OpenStruct.new(:url => tmp.first, :name => tmp.join(" ").capitalize)
    end
    erb :index
  end

  get '/test/:name' do 
    redirect "tests/test_#{params[:name]}.html"
  end

  # ------ for ajax testing

  get '/ajax/hello' do 
    %q{$("content").update("<H2>Hello world!</H2>");}
  end

  get '/ajax/content' do 
    "Pack my box with <em>five dozen</em> liquor jugs! Oh, how <strong>quickly</strong> daft jumping zebras vex..."
  end

  get '/ajax/empty' do 
    ""
  end

  post '/ajax/empty' do 
    ""
  end

  post '/tests/test_form.html' do
    "ok"
  end

  get '/ajax/data' do 
    json :test => 123
  end

  get '/ajax/response' do 
    json :test => 123
  end

  get '/ajax/response/1' do 
    json :test => 123
  end

  get '/ajax/response/2' do 
    response.body = ""
  end

  get '/ajax/response/3' do 
    json :test => 123
  end

  get '/ajax/response/4' do 
    {"test" => 123}
  end

  get '/ajax/response/5' do 
    json '{});window.attacked = true;({}'
  end

  get '/ajax/response/6' do 
    response.headers['X-JSON'] = '{"test": "hello #éà"}'
  end

  get '/ajax/response/7' do 
    json ""
  end

  get '/ajax/response/8' do 
    response.headers['X-TEST'] = 'some value'
  end

  get '/ajax/response/9' do 
    response.headers["one"] = "two"
    response.headers["three"] = "four"
  end

  post '/ajax/response/10' do 
    json "cool=1&bad=2&cool=3&bad=4"
  end

  get '/ajax/response/11' do 
    response.headers['Content-Type'] = "text/javascript"
    %q{$("content").update("<H2>Hello world!</H2>");}
  end

  get '/ajax/response/12' do 
    json '{});window.attacked = true;({}'
  end

  get '/ajax/response/13' do 
    response.headers['X-JSON'] = '{});window.attacked = true;({}'
  end

  get '/ajax/response/14' do 
    response.headers['Content-Type'] = 'application/xml'
    %q{<?xml version="1.0" encoding="UTF-8" ?><name attr="foo">bar</name>}
  end

  get '/ajax/response/15' do 
    response.headers['Content-Type'] = 'application/javascript'
    %q{$("content").update("<H2>Hello world!</H2>");} 
  end

  post '/ajax/response/16' do 
    response.headers['Content-Type'] = 'application/bogus'
  end

end 


at_exit do
  Tests::stop
  puts "==== shutting down"
end





