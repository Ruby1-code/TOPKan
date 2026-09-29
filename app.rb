require "sinatra"
require "sequel"
require "bcrypt"
require "uri"

set :bind, "0.0.0.0"
set :port, ENV.fetch("PORT", 4567)
set :database_url, ENV["DATABASE_URL"]

database_url = ENV["DATABASE_URL"]
if database_url
  # Render provides postgres:// URLs; the pg adapter expects postgresql://.
  database_url = database_url.sub(/\Apostgres:\/\//, "postgresql://")
  DB = Sequel.connect(database_url, max_connections: ENV.fetch("WEB_CONCURRENCY", 2).to_i * 5)
else
  Dir.mkdir("db") unless Dir.exist?("db")
  DB = Sequel.connect("sqlite://db/topkan.sqlite3")
end

DB.create_table?(:people) do
  primary_key :id
  String :first_name, null: false
  String :last_name, null: false
  String :email, null: false, unique: true
  String :password, null: false
end

PEOPLE = DB[:people]

helpers do
  def h(value)
    Rack::Utils.escape_html(value.to_s)
  end

  def person_params
    {
      first_name: params[:first_name].to_s.strip,
      last_name: params[:last_name].to_s.strip,
      email: params[:email].to_s.strip.downcase,
      password: params[:password].to_s
    }
  end

  def valid_person?(person, require_password: true)
    return "First name is required." if person[:first_name].empty?
    return "Last name is required." if person[:last_name].empty?
    return "Enter a valid email address." unless person[:email].match?(/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/)
    return "Password must be at least 8 characters." if require_password && person[:password].length < 8
    nil
  end

  def go_home(message = nil, type: "success")
    session[:flash] = { message: message, type: type } if message
    redirect "/"
  end

  def go_directory(message = nil, type: "success")
    session[:flash] = { message: message, type: type } if message
    redirect "/directory"
  end
end

enable :sessions
set :session_secret, ENV.fetch("SESSION_SECRET", "local-development-secret-change-this-please-1234567890abcdef0123456789")
set :protection, except: :path_traversal

before do
  content_type :html, charset: "utf-8"
  if request.path == "/directory" || request.path.start_with?("/people/") || request.path == "/people"
    unless session[:person_id] && PEOPLE.where(id: session[:person_id]).first
      session.clear
      redirect "/"
    end
  end
end

get "/" do
  if session[:person_id] && PEOPLE.where(id: session[:person_id]).first
    redirect "/directory"
  end
  @setup_mode = PEOPLE.count.zero?
  @flash = session.delete(:flash)
  erb :login
end

post "/login" do
  email = params[:email].to_s.strip.downcase
  person = PEOPLE.where(email: email).first
  if person && BCrypt::Password.new(person[:password]) == params[:password].to_s
    session.clear
    session[:person_id] = person[:id]
    redirect "/directory"
  else
    go_home("Email or password is incorrect.", type: "error")
  end
end

post "/setup" do
  halt 404, "Not found" unless PEOPLE.count.zero?

  person = person_params
  if (error = valid_person?(person))
    return go_home(error, type: "error")
  end

  begin
    id = PEOPLE.insert(first_name: person[:first_name], last_name: person[:last_name], email: person[:email], password: BCrypt::Password.create(person[:password]))
    session.clear
    session[:person_id] = id
    redirect "/directory"
  rescue Sequel::UniqueConstraintViolation
    go_home("That email address is already in the database.", type: "error")
  end
end

post "/logout" do
  session.clear
  redirect "/"
end

get "/directory" do
  @query = params[:q].to_s.strip
  dataset = PEOPLE.order(Sequel.desc(:id))
  unless @query.empty?
    pattern = "%#{@query.gsub(/[\\%_]/) { |char| "\\#{char}" }}%"
    dataset = dataset.where(Sequel.ilike(:first_name, pattern) | Sequel.ilike(:last_name, pattern) | Sequel.ilike(:email, pattern))
  end
  @people = dataset.all
  @flash = session.delete(:flash)
  @current_person = PEOPLE.where(id: session[:person_id]).first
  erb :index
end

post "/people" do
  person = person_params
  if (error = valid_person?(person))
    return go_home(error, type: "error")
  end

  begin
    PEOPLE.insert(first_name: person[:first_name], last_name: person[:last_name], email: person[:email], password: BCrypt::Password.create(person[:password]))
    go_directory("Record added.")
  rescue Sequel::UniqueConstraintViolation
    go_directory("That email address is already in the database.", type: "error")
  end
end

post "/people/:id/update" do
  id = Integer(params[:id], 10) rescue nil
  person = person_params
  return go_directory("Record not found.", type: "error") unless id && PEOPLE.where(id: id).first

  error = valid_person?(person, require_password: false)
  return go_directory(error, type: "error") if error

  values = { first_name: person[:first_name], last_name: person[:last_name], email: person[:email] }
  values[:password] = BCrypt::Password.create(person[:password]) unless person[:password].empty?
  begin
    PEOPLE.where(id: id).update(values)
    go_directory("Record updated.")
  rescue Sequel::UniqueConstraintViolation
    go_directory("That email address is already in the database.", type: "error")
  end
end

post "/people/:id/delete" do
  id = Integer(params[:id], 10) rescue nil
  return go_directory("Record not found.", type: "error") unless id && PEOPLE.where(id: id).first

  halt 400, "You cannot delete the last directory record." if PEOPLE.count <= 1
  PEOPLE.where(id: id).delete
  go_directory("Record deleted.")
end

not_found do
  "<h1>Not found</h1><p><a href='/'>Return to TOPKan</a></p>"
end
