require "sinatra"
require "sequel"
require "bcrypt"
require "uri"
require "digest"
require "json"
require "base64"
require "webauthn"

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

Sequel.extension :migration
Sequel::Migrator.run(DB, File.join(__dir__, "db", "migrations"))

PEOPLE = DB[:people]
PASSKEYS = DB[:passkeys]

WEBAUTHN_ORIGIN = ENV.fetch("WEBAUTHN_ORIGIN", ENV.fetch("RENDER_EXTERNAL_URL", "http://localhost:4567")).sub(%r{/\z}, "")
WEBAUTHN_URI = URI.parse(WEBAUTHN_ORIGIN)
WebAuthn.configure do |config|
  config.allowed_origins = [WEBAUTHN_ORIGIN]
  config.rp_id = WEBAUTHN_URI.host
  config.rp_name = "TOPKan"
end

helpers do
  def h(value)
    Rack::Utils.escape_html(value.to_s)
  end

  def person_params
    number_text = params[:sNumber].to_s.strip
    {
      first_name: params[:first_name].to_s.strip,
      last_name: params[:last_name].to_s.strip,
      email: params[:email].to_s.strip.downcase,
      password: params[:password].to_s,
      telephone1: params[:telephone1].to_s.strip.then { |value| value.empty? ? nil : value },
      sNumber: number_text.empty? ? nil : (Integer(number_text, 10) rescue :invalid),
      sName: params[:sName].to_s.strip.then { |value| value.empty? ? nil : value },
      comments: params[:comments].to_s.strip.then { |value| value.empty? ? nil : value },
      admin: params[:admin] == "1"
    }
  end

  def valid_person?(person, require_password: true)
    return "First name is required." if person[:first_name].empty?
    return "Last name is required." if person[:last_name].empty?
    return "Enter a valid email address." unless person[:email].match?(/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/)
    return "Password must be at least 8 characters." if require_password && person[:password].length < 8
    return "Telephone must be 20 characters or fewer." if person[:telephone1].to_s.length > 20
    return "sNumber must be a whole number." if person[:sNumber] == :invalid
    return "sName must be 50 characters or fewer." if person[:sName].to_s.length > 50
    return "Comments must be 500 characters or fewer." if person[:comments].to_s.length > 500
    nil
  end

  def current_person
    @current_person ||= PEOPLE.where(id: session[:person_id]).first if session[:person_id]
  end

  def go_home(message = nil, type: "success")
    session[:flash] = { message: message, type: type } if message
    redirect "/"
  end

  def go_directory(message = nil, type: "success")
    session[:flash] = { message: message, type: type } if message
    redirect "/directory"
  end

  def json_body
    JSON.parse(request.body.read)
  rescue JSON::ParserError, TypeError
    {}
  end

  def json_response(payload, status_code = 200)
    status status_code
    content_type :json
    JSON.generate(payload)
  end

  def require_same_origin!
    halt 403, "Request origin rejected." unless request.env["HTTP_ORIGIN"] == WEBAUTHN_ORIGIN
  end

  def passkey_user_id(person_id)
    Base64.urlsafe_encode64("topkan-person-#{person_id}", padding: false)
  end

  def serialize_options(options)
    JSON.generate(options.as_json)
  end

  def authenticate_passkey!(person)
    session.clear
    session[:person_id] = person[:id]
  end
end

enable :sessions
session_secret = ENV.fetch("SESSION_SECRET", "local-development-secret-change-this-please-1234567890abcdef0123456789")
set :session_secret, Digest::SHA256.hexdigest(session_secret)
set :protection, except: :path_traversal

before do
  content_type :html, charset: "utf-8"
  if request.path == "/directory" || request.path.start_with?("/people/") || request.path == "/people" || request.path.start_with?("/account/")
    unless current_person
      session.clear
      redirect "/"
    end
    halt 403, "Admin access required." if request.post? && request.path.start_with?("/people") && !current_person[:admin]
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

post "/passkeys/login/options" do
  require_same_origin!
  email = json_body["email"].to_s.strip.downcase
  person = PEOPLE.where(email: email).first
  credentials = person ? PASSKEYS.where(person_id: person[:id]).all : []
  return json_response({ error: "No passkey is available for that email. Use your password or check the email." }, 422) if credentials.empty?

  options = WebAuthn::Credential.options_for_get(
    allow: credentials.map { |credential| credential[:credential_id] },
    user_verification: "required"
  )
  session[:passkey_login] = { "challenge" => options.challenge, "person_id" => person[:id], "issued_at" => Time.now.to_i }
  content_type :json
  serialize_options(options)
end

post "/passkeys/login" do
  require_same_origin!
  ceremony = session.delete(:passkey_login)
  challenge = ceremony && ceremony["issued_at"].to_i >= Time.now.to_i - 300 ? ceremony["challenge"] : nil
  return json_response({ error: "Passkey sign-in expired. Try again." }, 401) unless challenge

  credential = WebAuthn::Credential.from_get(json_body)
  stored = PASSKEYS.where(credential_id: credential.id, person_id: ceremony["person_id"]).first
  return json_response({ error: "Passkey could not be verified." }, 401) unless stored

  credential.verify(challenge, public_key: stored[:public_key], sign_count: stored[:sign_count], user_verification: true)
  PASSKEYS.where(id: stored[:id]).update(sign_count: credential.sign_count.to_i)
  person = PEOPLE.where(id: stored[:person_id]).first
  return json_response({ error: "Account not found." }, 401) unless person

  authenticate_passkey!(person)
  json_response({ redirect: "/directory" })
rescue WebAuthn::Error, ArgumentError, KeyError, TypeError
  json_response({ error: "Passkey sign-in failed. Try again or use your password." }, 401)
end

post "/setup" do
  halt 404, "Not found" unless PEOPLE.count.zero?

  person = person_params
  if (error = valid_person?(person))
    return go_home(error, type: "error")
  end

  begin
    id = PEOPLE.insert(
      first_name: person[:first_name], last_name: person[:last_name], email: person[:email],
      password: BCrypt::Password.create(person[:password]), telephone1: person[:telephone1],
      sNumber: person[:sNumber], sName: person[:sName], comments: person[:comments], admin: true
    )
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

get "/account/password" do
  @current_person = current_person
  @flash = session.delete(:flash)
  erb :change_password
end

get "/account/passkeys" do
  @current_person = current_person
  @passkeys = PASSKEYS.where(person_id: @current_person[:id]).order(:id).all
  @flash = session.delete(:flash)
  erb :passkeys
end

post "/account/passkeys/options" do
  require_same_origin!
  person = current_person
  body = json_body
  unless BCrypt::Password.new(person[:password]) == body["current_password"].to_s
    return json_response({ error: "Current password is incorrect." }, 422)
  end

  credentials = PASSKEYS.where(person_id: person[:id]).all
  options = WebAuthn::Credential.options_for_create(
    user: { id: passkey_user_id(person[:id]), name: person[:email], display_name: "#{person[:first_name]} #{person[:last_name]}" },
    exclude: credentials.map { |credential| credential[:credential_id] },
    authenticator_selection: { resident_key: "required", user_verification: "required" }
  )
  session[:passkey_creation] = { "challenge" => options.challenge, "person_id" => person[:id], "issued_at" => Time.now.to_i }
  content_type :json
  serialize_options(options)
end

post "/account/passkeys" do
  require_same_origin!
  ceremony = session.delete(:passkey_creation)
  challenge = ceremony && ceremony["issued_at"].to_i >= Time.now.to_i - 300 ? ceremony["challenge"] : nil
  return json_response({ error: "Passkey setup expired. Try again." }, 401) unless challenge && ceremony["person_id"] == current_person[:id]

  credential = WebAuthn::Credential.from_create(json_body)
  credential.verify(challenge, user_verification: true)
  count = PASSKEYS.where(person_id: current_person[:id]).count + 1
  PASSKEYS.insert(
    person_id: current_person[:id], credential_id: credential.id, public_key: credential.public_key,
    sign_count: credential.sign_count.to_i, label: "Passkey #{count}"
  )
  json_response({ message: "Passkey added." })
rescue WebAuthn::Error, ArgumentError, KeyError, TypeError, Sequel::UniqueConstraintViolation
  json_response({ error: "Could not add that passkey. Please try again." }, 422)
end

post "/account/passkeys/:id/delete" do
  require_same_origin!
  unless BCrypt::Password.new(current_person[:password]) == params[:current_password].to_s
    session[:flash] = { message: "Current password is incorrect.", type: "error" }
    return redirect "/account/passkeys"
  end

  PASSKEYS.where(id: Integer(params[:id], 10), person_id: current_person[:id]).delete
  session[:flash] = { message: "Passkey removed.", type: "success" }
  redirect "/account/passkeys"
rescue ArgumentError
  session[:flash] = { message: "Passkey not found.", type: "error" }
  redirect "/account/passkeys"
end

post "/account/password" do
  current_password = params[:current_password].to_s
  new_password = params[:new_password].to_s
  confirmation = params[:password_confirmation].to_s

  unless BCrypt::Password.new(current_person[:password]) == current_password
    session[:flash] = { message: "Current password is incorrect.", type: "error" }
    return redirect "/account/password"
  end

  if new_password.length < 8
    session[:flash] = { message: "New password must be at least 8 characters.", type: "error" }
    return redirect "/account/password"
  end

  unless new_password == confirmation
    session[:flash] = { message: "New password and confirmation do not match.", type: "error" }
    return redirect "/account/password"
  end

  PEOPLE.where(id: current_person[:id]).update(password: BCrypt::Password.create(new_password))
  session[:flash] = { message: "Your password has been changed.", type: "success" }
  redirect "/directory"
end

get "/directory" do
  @query = params[:q].to_s.strip
  dataset = PEOPLE.order(Sequel.desc(:id))
  unless @query.empty?
    pattern = "%#{@query.gsub(/[\\%_]/) { |char| "\\#{char}" }}%"
    dataset = dataset.where(
      Sequel.ilike(:first_name, pattern) | Sequel.ilike(:last_name, pattern) |
      Sequel.ilike(:email, pattern) | Sequel.ilike(:telephone1, pattern) |
      Sequel.ilike(:sName, pattern) | Sequel.cast(:sNumber, String).ilike(pattern) |
      Sequel.ilike(:comments, pattern)
    )
  end
  @people = dataset.all
  @flash = session.delete(:flash)
  @current_person = current_person
  erb :index
end

post "/people" do
  person = person_params
  if (error = valid_person?(person))
    return go_directory(error, type: "error")
  end

  begin
    PEOPLE.insert(
      first_name: person[:first_name], last_name: person[:last_name], email: person[:email],
      password: BCrypt::Password.create(person[:password]), telephone1: person[:telephone1],
      sNumber: person[:sNumber], sName: person[:sName], comments: person[:comments], admin: person[:admin]
    )
    go_directory("Record added.")
  rescue Sequel::UniqueConstraintViolation
    go_directory("That email address is already in the database.", type: "error")
  end
end

post "/people/:id/update" do
  id = Integer(params[:id], 10) rescue nil
  person = person_params
  existing = id && PEOPLE.where(id: id).first
  return go_directory("Record not found.", type: "error") unless existing

  error = valid_person?(person, require_password: false)
  return go_directory(error, type: "error") if error

  if existing[:admin] && !person[:admin] && PEOPLE.where(admin: true).count <= 1
    return go_directory("The last admin account cannot be demoted.", type: "error")
  end

  values = {
    first_name: person[:first_name], last_name: person[:last_name], email: person[:email],
    telephone1: person[:telephone1], sNumber: person[:sNumber], sName: person[:sName], comments: person[:comments],
    admin: person[:admin]
  }
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
  target = PEOPLE.where(id: id).first
  halt 400, "The last admin account cannot be deleted." if target[:admin] && PEOPLE.where(admin: true).count <= 1
  PEOPLE.where(id: id).delete
  go_directory("Record deleted.")
end

not_found do
  "<h1>Not found</h1><p><a href='/'>Return to TOPKan</a></p>"
end
