# Copyright 2016 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'google/apis/gmail_v1'
require 'base_cli'
require 'rmail'
require 'pp'
require 'json'

module Samples
  # Examples for the Gmail API
  #
  # Sample usage:
  #
  #     $ ./google-api-samples gmail send 'Hello there!' \
  #       --to='recipient@example.com' --from='user@example.com' \
  #       --subject='Hello'
  #
  class Gmail < BaseCli
    Gmail = Google::Apis::GmailV1

    desc 'get ID', 'Get a message for an id with the gmail API'
    def get(id)
      gmail = Gmail::GmailService.new
      gmail.authorization = user_credentials_for(Gmail::AUTH_SCOPE)

      result = gmail.get_user_message('me', id)
      payload = result.payload
      headers = payload.headers

      date = headers.any? { |h| h.name == 'Date' } ? headers.find { |h| h.name == 'Date' }.value : ''
      from = headers.any? { |h| h.name == 'From' } ? headers.find { |h| h.name == 'From' }.value : ''
      to = headers.any? { |h| h.name == 'To' } ? headers.find { |h| h.name == 'To' }.value : ''
      subject = headers.any? { |h| h.name == 'Subject' } ? headers.find { |h| h.name == 'Subject' }.value : ''

      body = payload.body.data
      if body.nil? && payload.parts.any?
        body = payload.parts.map { |part| part.body.data }.join
      end

      puts "id: #{result.id}"
      puts "date: #{date}"
      puts "from: #{from}"
      puts "to: #{to}"
      puts "subject: #{subject}"
      puts "body: #{body}"
    end

    desc 'send TEXT', 'Send a message with the gmail API'
    method_option :to, type: :string, required: true
    method_option :from, type: :string, required: true
    method_option :subject, type: :string, required: true
    def send(body)
      gmail = Gmail::GmailService.new
      gmail.authorization = user_credentials_for(Gmail::AUTH_SCOPE)

      message = RMail::Message.new
      message.header['To'] = options[:to]
      message.header['From'] = options[:from]
      message.header['Subject'] = options[:subject]
      message.body = body

      gmail.send_user_message('me',
                              upload_source: StringIO.new(message.to_s),
                              content_type: 'message/rfc822')
    end

    desc 'list', 'list messages with the gmail API'
    method_option :limit, type: :numeric, default: 100
    def list
      gmail = Gmail::GmailService.new
      gmail.authorization = user_credentials_for(Gmail::AUTH_SCOPE)

      messages = []
      next_page = nil
      begin
        result = gmail.list_user_messages('me', max_results: [options[:limit], 500].min, page_token: next_page)
        messages += result.messages
        break if messages.size >= options[:limit]
        next_page = result.next_page_token
      end while next_page

      puts "Found #{messages.size} messages"
    end

    desc 'search QUERY', 'Search messages matching the specified query with the gmail API'
    method_option :limit, type: :numeric, default: 100
    def search(query)
      gmail = Gmail::GmailService.new
      gmail.authorization = user_credentials_for(Gmail::AUTH_SCOPE)

      ids =
        gmail.fetch_all(max: options[:limit], items: :messages) do |token|
          gmail.list_user_messages('me', max_results: [options[:limit], 500].min, q: query, page_token: token)
        end.map(&:id)

      callback = lambda do |result, err|
        if err
          puts "error: #{err.inspect}"
        else
          headers = result.payload.headers
          date = headers.any? { |h| h.name == 'Date' } ? headers.find { |h| h.name == 'Date' }.value : ''
          subject = headers.any? { |h| h.name == 'Subject' } ? headers.find { |h| h.name == 'Subject' }.value : ''
          puts "#{result.id}, #{date}, #{subject}"
        end
      end

      ids.each_slice(1000) do |ids_array|
        gmail.batch do |gm|
          ids_array.each { |id| gm.get_user_message('me', id, &callback) }
        end
      end
    end


    desc 'impersonate and update email signature', 'Update the email signature of another user'
    method_option :impersonated_email, type: :string, required: true
    def update_email_signature(new_signature_content)
      gmail = Gmail::GmailService.new

      # You can download a client_secret.json from the service account page
      # of your developer's console

      attrs = {
        json_key_io: 'client_secret.json',
        scope: [ Gmail::AUTH_GMAIL_SETTINGS_BASIC ]
      }

      auth = Google::Auth::ServiceAccountCredentials.make_creds(attrs)
      impersonate_auth = auth.dup
      impersonate_auth.sub = impersonated_email

      user_id = impersonated_email
      send_as_email = update_user_setting_send_as


      gmail.authorization = impersonate_auth

      send_as_object = {"signature": new_signature_content}
      # options: {} is necessary for method to be called correctly.
      result = service.patch_user_setting_send_as(user_id, send_as_email, send_as_object, options: {})


      puts "signature of #{impersonated_email} is now: #{result.signature}"
    end

    desc 'user_watch', 'call users.watch REST API'
    method_option :email, type: :string, required: false
    method_option :topic, type: :string, required: true
    def user_watch
      gmail = Gmail::GmailService.new
      gmail.authorization = user_credentials_for(Gmail::AUTH_SCOPE)

      user = options[:email] || 'me'
      watch_request = Google::Apis::GmailV1::WatchRequest.new(
                        label_ids: ['UNREAD'],
                        label_filter_action: 'include',
                        topic_name: options[:topic]
                      )
      watch_response = gmail.watch_user(user, watch_request) #{|result,err| }

      pp watch_response
      if watch_response
        File.open("watch_response.json", "w") do |fh|
          fh.print(JSON.pretty_generate({expiration: watch_response.expiration / 1000, history_id: watch_response.history_id}))
        end
      end
    end

    desc 'user_stop', 'call users.stop REST API'
    method_option :email, type: :string, required: false
    def user_stop
      gmail = Gmail::GmailService.new
      gmail.authorization = user_credentials_for(Gmail::AUTH_SCOPE)

      user = options[:email] || 'me'
      gmail.stop_user(user)
      puts "stopped watch"
    end

    desc 'user_history HISTORY_ID', 'call users.history REST API'
    method_option :email, type: :string, required: false
    def user_history(history_id)
      gmail = Gmail::GmailService.new
      gmail.authorization = user_credentials_for(Gmail::AUTH_SCOPE)
      user = options[:email] || 'me'
      list_history_response = gmail.list_user_histories(user, start_history_id: history_id, label_id: ["UNREAD"], history_types: ["messageAdded", "labelAdded"]) # 
      list_history_response.history.each do |hist|
        #pp hist
        puts "history_id: #{hist.id}"
        hist.messages.each do |message|
          puts "  messages      : #{message.id} thread_id: #{message.thread_id}"
        end
        unless hist.messages_added
          puts "  NO messages_added."
          next
        end
        hist.messages_added.each do |hist_message_added|
          puts "  messages_added: #{hist_message_added.message.id} thread_id: #{hist_message_added.message.thread_id}"
        end
      end
    end

    desc 'user_message ID', 'call users.messages.get REST API'
    method_option :email, type: :string, required: false
    def user_message(id)
      gmail = Gmail::GmailService.new
      gmail.authorization = user_credentials_for(Gmail::AUTH_SCOPE)
      user = options[:email] || 'me'
      result = gmail.get_user_message(user, id)
      #pp result.payload
      payload = result.payload
      headers = payload.headers

      date = headers.any? { |h| h.name == 'Date' } ? headers.find { |h| h.name == 'Date' }.value : ''
      from = headers.any? { |h| h.name == 'From' } ? headers.find { |h| h.name == 'From' }.value : ''
      to = headers.any? { |h| h.name == 'To' } ? headers.find { |h| h.name == 'To' }.value : ''
      subject = headers.any? { |h| h.name == 'Subject' } ? headers.find { |h| h.name == 'Subject' }.value : ''

      puts "id: #{result.id}"
      puts "date: #{date}"
      puts "from: #{from}"
      puts "to: #{to}"
      puts "subject: #{subject}"
    end
  end
end
