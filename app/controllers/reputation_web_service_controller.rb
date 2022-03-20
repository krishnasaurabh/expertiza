require 'json'
require 'uri'
require 'net/http'
require 'openssl'
require 'base64'

class ReputationWebServiceController < ApplicationController
  include AuthorizationHelper

  # checks for the user privileges before performing the action requested
  def action_allowed?
    current_user_has_ta_privileges?
  end

  def get_max_question_score(answers)
    begin
      answers.first.question.questionnaire.max_question_score
    rescue StandardError
      1
    end
  end

  def get_valid_answers_for_response(response)
    answers = Answer.where(response_id: response.id)
    valid_answer = answers.select { |a| (a.question.type == 'Criterion') && !a.answer.nil? }
    valid_answer.empty? ? nil : valid_answer
  end

  def calculate_peer_review_grade(valid_answer, max_question_score)
    temp_sum = 0
    weight_sum = 0
    valid_answer.each do |answer|
      temp_sum += answer.answer * answer.question.weight
      weight_sum += answer.question.weight
    end
    peer_review_grade = 100.0 * temp_sum / (weight_sum * max_question_score)
    peer_review_grade.round(4)
  end

  def get_peer_reviews_for_responses(reviewer_id, team_id, valid_response)
    peer_review_grades_list = []
    valid_response.each do |response|
      valid_answer = get_valid_answers_for_response(response)
      next if valid_answer.nil?

      review_grade = calculate_peer_review_grade(valid_answer, get_max_question_score(valid_answer))
      peer_review_grades_list << [reviewer_id, team_id, review_grade]
    end
    peer_review_grades_list
  end

  # db query, return peer reviews
  def get_peer_reviews(assignment_id_list, round_num, has_topic)
    raw_data_array = []
    ReviewResponseMap.where('reviewed_object_id in (?) and calibrate_to = ?', assignment_id_list, false).each do |response_map|
      reviewer = response_map.reviewer.user
      team = AssignmentTeam.find(response_map.reviewee_id)
      topic_condition = ((has_topic && (SignedUpTeam.where(team_id: team.id).first.is_waitlisted == false)) || !has_topic)
      last_valid_response = response_map.response.select { |r| r.round == round_num }.max
      valid_response = [last_valid_response] unless last_valid_response.nil?
      if (topic_condition == true) && !valid_response.nil? && !valid_response.empty?
        raw_data_array += get_peer_reviews_for_responses(reviewer.id, team.id, valid_response)
      end
    end
    raw_data_array
  end

  def get_ids_list(tables)
    tables.map { |table| table.id }
  end

  def get_scores(team_ids)
    quiz_questionnnaires = QuizQuestionnaire.where('instructor_id in (?)', team_ids)
    quiz_questionnnaire_ids = get_ids_list(quiz_questionnnaires)
    QuizResponseMap.where('reviewed_object_id in (?)', quiz_questionnnaire_ids).each do |response_map|
      quiz_score = response_map.quiz_score
      participant = Participant.find(response_map.reviewer_id)
      raw_data_array << [participant.user_id, response_map.reviewee_id, quiz_score]
    end
    raw_data_array
  end

  # special db query, return quiz scores
  def get_quiz_score(assignment_id_list)
    teams = AssignmentTeam.where('parent_id in (?)', assignment_id_list)
    team_ids = get_ids_list(teams)
    get_scores(team_ids)
  end

  def generate_json_body(results)
    request_body = {}
    results.each_with_index do |record, _index|
      request_body['submission' + record[1].to_s] = {} unless request_body.key?('submission' + record[1].to_s)
      request_body['submission' + record[1].to_s]['stu' + record[0].to_s] = record[2]
    end
    # sort the 2-dimension hash
    request_body.each { |k, v| request_body[k] = v.sort.to_h }
    request_body.sort.to_h
    request_body
  end

  def generate_json_for_peer_reviews(assignment_id_list, round_num = 2)
    has_topic = !SignUpTopic.where(assignment_id: assignment_id_list[0]).empty?

    peer_reviews_list = get_peer_reviews(assignment_id_list, round_num, has_topic)
    request_body = generate_json_body(peer_reviews_list)
    request_body
  end

  def generate_json_for_quiz_scores(assignment_id_list)
    participant_reviewee_map = get_quiz_score(assignment_id_list)
    request_body = generate_json_body(participant_reviewee_map)
    request_body
  end

  def client
    @max_assignment_id = Assignment.last.id
  end

  def encrypt_request_body(plain_data)
    # AES symmetric algorithm encrypts raw data
    aes_encrypted_request_data = aes_encrypt(plain_data)
    plain_data = aes_encrypted_request_data[0]

    # RSA asymmetric algorithm encrypts keys of AES
    encrypted_key = rsa_public_key1(aes_encrypted_request_data[1])
    encrypted_vi = rsa_public_key1(aes_encrypted_request_data[2])
    # fixed length 350

    plain_data.prepend('", "data":"')
    plain_data.prepend(encrypted_vi)
    plain_data.prepend(encrypted_key)
  end

  def format_into_JSON(data)
    data.prepend('{"keys":"')
    data << '"}'
    data.gsub!(/\n/, '\\n')
  end

  def decrypt_response(encrypted_data)
    encrypted_data = JSON.parse(encrypted_data)
    key = rsa_private_key2(encrypted_data['keys'][0, 350])
    vi = rsa_private_key2(encrypted_data['keys'][350, 350])
    # AES symmetric algorithm decrypts data
    aes_encrypted_response_data = encrypted_data['data']
    decrypted_data = aes_decrypt(aes_encrypted_response_data, key, vi)
    decrypted_data
  end

  def update_participants(response)
    JSON.parse(response.body.to_s).each do |alg, list|
      next unless alg == 'Hamer' || alg == 'Lauw'

      list.each do |id, rep|
        Participant.find_by(user_id: id).update(alg.to_sym => rep) unless /leniency/ =~ id.to_s
      end
    end
  end

  def process_response_body(response)
    # Decryption
    decrypt_response(response.body)

    @response = response
    @response_body = response.body

    update_participants(response)
    redirect_to action: 'client'
  end

  def add_expert_grades(body)
    @additional_info = 'add expert grades'
    case params[:assignment_id]
    when '754' # expert grades of Wiki contribution (754)
      body.prepend('"expert_grades": {"submission25030":95,"submission25031":92,"submission25033":88,"submission25034":98,"submission25035":100,"submission25037":95,"submission25038":95,"submission25039":93,"submission25040":96,"submission25041":90,"submission25042":100,"submission25046":95,"submission25049":90,"submission25050":88,"submission25053":91,"submission25054":96,"submission25055":94,"submission25059":96,"submission25071":85,"submission25082":100,"submission25086":95,"submission25097":90,"submission25098":85,"submission25102":97,"submission25103":94,"submission25105":98,"submission25114":95,"submission25115":94},')
    end
  end

  def add_quiz_scores(body)
    @additional_info = 'add quiz scores'
    assignment_id_list_quiz = get_assignment_id_list(params[:assignment_id].to_i, params[:another_assignment_id].to_i)
    quiz_str =  generate_json_for_quiz_scores(assignment_id_list_quiz).to_json
    quiz_str[0] = ''
    quiz_str.prepend('"quiz_scores":{')
    quiz_str += ','
    quiz_str = quiz_str.gsub('"N/A"', '20.0')
    body.prepend(quiz_str)
  end

  def add_hamer_reputation_values
    @additional_info = 'add initial hamer reputation values'
  end

  def add_lauw_reputation_values
    @additional_info = 'add initial lauw reputation values'
  end

  def get_assignment_id_list(assignment_id_one, assignment_id_two)
    assignment_id_list = []
    assignment_id_list << assignment_id_one
    assignment_id_list << assignment_id_two unless assignment_id_two.zero?
    assignment_id_list
  end

  def prepare_request_body
    req = Net::HTTP::Post.new('/reputation/calculations/reputation_algorithms', initheader: { 'Content-Type' => 'application/json', 'charset' => 'utf-8' })
    curr_assignment_id = (params[:assignment_id].empty? ? '754' : params[:assignment_id])
    assignment_id_list_peers = get_assignment_id_list(curr_assignment_id, params[:another_assignment_id].to_i)
    req.body = generate_json_for_peer_reviews(assignment_id_list_peers, params[:round_num].to_i).to_json
    # req.body = json_generator(curr_assignment_id, params[:another_assignment_id].to_i, params[:round_num].to_i, 'peer review grades').to_json
    req.body[0] = '' # remove the first '{'
    @assignment_id = params[:assignment_id]
    @round_num = params[:round_num]
    @algorithm = params[:algorithm]
    @another_assignment_id = params[:another_assignment_id]

    if params[:checkbox][:expert_grade] == 'Add expert grades'
      add_expert_grades(req.body)
    elsif params[:checkbox][:hamer] == 'Add initial Hamer reputation values'
      add_hamer_reputation_values
    elsif params[:checkbox][:lauw] == 'Add initial Lauw reputation values'
      add_lauw_reputation_values
    elsif params[:checkbox][:quiz] == 'Add quiz scores'
      add_quiz_scores(req.body)
    else
      @additional_info = ''
    end


    req.body.prepend('{')
    @request_body = req.body
    # Encrypting the request body data
    req.body = encrypt_request_body(req.body)

    # request body should be in JSON format.
    req.body = format_into_JSON(req.body)
    req
  end

  def send_post_request
    req = prepare_request_body
    response = Net::HTTP.new('peerlogic.csc.ncsu.edu').start { |http| http.request(req) }
    process_response_body(response)
  end

  def rsa_public_key1(data)
    public_key_file = 'public1.pem'
    public_key = OpenSSL::PKey::RSA.new(File.read(public_key_file))
    encrypted_string = Base64.encode64(public_key.public_encrypt(data))

    encrypted_string
  end

  def rsa_private_key2(ciphertext)
    private_key_file = 'private2.pem'
    password = "ZXhwZXJ0aXph\n"
    encrypted_string = ciphertext
    private_key = OpenSSL::PKey::RSA.new(File.read(private_key_file), Base64.decode64(password))
    string = private_key.private_decrypt(Base64.decode64(encrypted_string))

    string
  end

  def aes_encrypt(data)
    cipher = OpenSSL::Cipher::AES.new(256, :CBC)
    cipher.encrypt
    key = cipher.random_key
    iv = cipher.random_iv
    ciphertext = Base64.encode64(cipher.update(data) + cipher.final)
    [ciphertext, key, iv]
  end

  def aes_decrypt(ciphertext, key, iv)
    decipher = OpenSSL::Cipher::AES.new(256, :CBC)
    decipher.decrypt
    decipher.key = key
    decipher.iv = iv
    plain = decipher.update(Base64.decode64(ciphertext)) + decipher.final
    plain
  end
end
