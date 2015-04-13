class @Summernote
  constructor: ->
    $('.summernote').summernote(
      height: 300,
      minHeight: null,
      maxHeight: null,
      toolbar: [
        ['style', ['style']],
        ['color', ['color']],
        ['font', ['bold', 'italic', 'underline', 'clear']],
        ['para', ['ul', 'ol', 'paragraph']],
        ['table', ['table']],
        ['insert', ['link', 'picture']],
        ['misc', ['fullscreen', 'codeview']]
      ],
      onImageUpload: (files, editor, welEditable) ->
        data = new FormData()
        data.append('image[file]', files[0])
        $.ajax({
          url: '/images'
          data: data,
          type: 'POST',
          cache: false,
          processData: false,
          contentType: false,
          dataType: 'json',
          success: (data) ->
            editor.insertImage(welEditable, data.image.medium)
        })
    )
