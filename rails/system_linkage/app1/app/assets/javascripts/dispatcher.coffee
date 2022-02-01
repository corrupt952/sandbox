class @Dispatcher
  constructor: ->
    controller = $('body').data('controller')

    switch controller
      when 'posts'
        new Summernote()

$(document).on 'page:change', ->
  new Dispatcher()
