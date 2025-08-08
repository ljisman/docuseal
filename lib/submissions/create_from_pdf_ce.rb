# frozen_string_literal: true

module Submissions
  module CreateFromPdfCe
    BaseError = Class.new(StandardError)

    module_function

    def call(current_user:, current_account:, payload:)
      raise BaseError, 'documents are required' if payload[:documents].blank?

      Template.transaction do
        template = Template.create!(
          account: current_account,
          author: current_user,
          name: payload[:name].presence || 'Untitled',
          source: 'api'
        )

        template.submitters = build_template_submitters(payload[:submitters])

        fields = []
        schema = []

        Array.wrap(payload[:documents]).each do |doc|
          io = to_io(doc[:file])
          raise BaseError, 'Invalid file' unless io

          data = io.read
          filename = doc[:name].presence || 'document.pdf'

          blob = ActiveStorage::Blob.create_and_upload!(
            io: StringIO.new(data),
            filename: filename,
            content_type: 'application/pdf'
          )

          attachment = ActiveStorage::Attachment.create!(
            blob: blob,
            name: :documents,
            record: template
          )

          Templates::ProcessDocument.call(attachment, data)

          schema << { 'attachment_uuid' => attachment.uuid, 'name' => filename }

          page_sizes = extract_pdf_page_sizes(data)

          Array.wrap(doc[:fields]).each do |field|
            submitter_uuid = find_submitter_uuid(template.submitters, field[:role])
            raise BaseError, "Unknown role #{field[:role]}" if field[:role].present? && submitter_uuid.nil?

            field_hash = {
              'uuid' => SecureRandom.uuid,
              'submitter_uuid' => submitter_uuid || template.submitters.first['uuid'],
              'name' => field[:name],
              'type' => field[:type],
              'required' => field[:required].present?,
              'preferences' => {}
            }

            field_hash['areas'] = Array.wrap(field[:areas]).map do |area|
              page_index = area[:page].to_i - 1
              normalize_area(area, page_sizes[page_index]).merge(
                'attachment_uuid' => attachment.uuid,
                'page' => page_index
              )
            end

            fields << field_hash
          end
        end

        template.fields = fields
        template.schema = schema
        template.save!

        submissions = Submissions.create_from_submitters(
          template: template,
          user: current_user,
          source: :api,
          submitters_order: payload[:order] || 'preserved',
          submissions_attrs: [
            { submitters: Array.wrap(payload[:submitters]), name: payload[:name], expire_at: payload[:expire_at] }
          ],
          params: payload.slice(:send_email, :reply_to, :bcc_completed, :completed_redirect_url)
        )

        submission = submissions.first

        WebhookUrls.enqueue_events(submissions, 'submission.created')
        Submissions.send_signature_requests(submissions)

        submission.submitters.each do |submitter|
          next unless submitter.completed_at?

          ProcessSubmitterCompletionJob.perform_async('submitter_id' => submitter.id,
                                                      'send_invitation_email' => false)
        end

        SearchEntries.enqueue_reindex(submissions)

        submission
      end
    rescue DownloadUtils::UnableToDownload => e
      raise BaseError, e.message
    end

    def to_io(file)
      return StringIO.new(Base64.decode64(file.to_s)) unless file.to_s.start_with?('http')

      resp = DownloadUtils.call(file)
      StringIO.new(resp.body)
    rescue StandardError
      nil
    end

    def normalize_area(area, page_size)
      width = page_size[:width].to_f
      height = page_size[:height].to_f
      {
        'x' => area[:x].to_f / width,
        'y' => (height - area[:y].to_f - area[:h].to_f) / height,
        'w' => area[:w].to_f / width,
        'h' => area[:h].to_f / height
      }
    end

    def extract_pdf_page_sizes(data)
      pdf = HexaPDF::Document.new(io: StringIO.new(data))
      pdf.pages.map do |page|
        box = page[:CropBox] || page[:MediaBox]
        { width: box[2] - box[0], height: box[3] - box[1] }
      end
    end

    def find_submitter_uuid(submitters, role)
      return if role.blank?

      submitters.find { |s| s['name'].casecmp(role.to_s).zero? }&.dig('uuid')
    end

    def build_template_submitters(submitters)
      roles = Array.wrap(submitters).map { |s| s[:role].presence || Template::DEFAULT_SUBMITTER_NAME }
      roles.uniq.map { |name| { 'name' => name, 'uuid' => SecureRandom.uuid } }
    end
  end
end
