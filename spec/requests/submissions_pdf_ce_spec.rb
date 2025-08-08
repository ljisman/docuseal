# frozen_string_literal: true

describe 'Submission PDF CE API' do
  let(:account) { create(:account, :with_testing_account) }
  let(:user) { create(:user, account:) }

  describe 'POST /api/submissions/pdf_ce' do
    it 'creates a submission from pdf' do
      pdf_data = Base64.encode64(Rails.root.join('spec/fixtures/sample-document.pdf').binread)

      post '/api/submissions/pdf_ce',
           headers: { 'x-auth-token': user.access_token.token },
           params: {
             name: 'Test',
             documents: [
               {
                 name: 'sample.pdf',
                 file: pdf_data,
                 fields: [
                   {
                     name: 'Sig1',
                     type: 'signature',
                     role: 'First Party',
                     areas: [{ x: 120, y: 520, w: 180, h: 40, page: 1 }]
                   }
                 ]
               }
             ],
             submitters: [
               { email: 'alice@example.com', name: 'Alice', role: 'First Party' }
             ],
             send_email: false
           }.to_json

      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body['id']).to eq(Submission.last.id)
      expect(body['submitters'].first['embed_src']).to include('/s/')
    end
  end
end
