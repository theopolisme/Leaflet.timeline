###
Leaflet.timeline

Show any arbitrary GeoJSON objects changing over time

(c) 2014-15 Jonathan Skeate
https://github.com/skeate/Leaflet.timeline
http://leafletjs.com
###

L.TimelineVersion = '0.4.0'

# better range lookup performance.
# http://jsperf.com/range-lookup-algorithm-comparison
# not sure if my RB tree implementation was flawed in some way but
# for some reason a plain, non-self-balancing interval tree worked better
class IntervalTree
  constructor: ->
    @_root = null
    @_list = null
  insert: (begin, end, value, node, parent, parentSide) ->
    if node == undefined then node = @_root
    if !node
      new_node =
        low: begin
        high: end
        max: end
        data: value
        left: null
        right: null
        parent: parent
      if parent
        parent[parentSide] = new_node
      else
        @_root = new_node
      return new_node
    else
      if begin < node.low or begin == node.low and end < node.high
        new_node = @insert begin, end, value, node.left, node, 'left'
      else
        new_node = @insert begin, end, value, node.right, node, 'right'
      node.max = Math.max node.max, new_node.max
    return new_node
  lookup: (value, node) ->
    if node == undefined
      node = @_root
      @_list = []
    if node == null or node.max < value then return []
    if node.left != null then @lookup value, node.left
    if node.low <= value
      if node.high >= value then @_list.push node.data
      @lookup value, node.right
    return @_list


L.Timeline = L.GeoJSON.extend
  includes: L.Mixin.Events
  times: []
  displayedLayers: []
  ranges: null
  options:
    position: "bottomleft"
    formatDate: (date) -> ""
    enablePlayback: true
    steps: 1000
    duration: 10000
    showTicks: true
    waitToUpdateMap: false
  initialize: (timedGeoJSON, options) ->
    L.GeoJSON.prototype.initialize.call this, undefined, options
    L.extend @options, options
    @ranges = new IntervalTree()
    if options.intervalFromFeature?
      @intervalFromFeature = options.intervalFromFeature.bind(this)
    if options.addData?
      @addData = options.addData.bind(this)
    if options.doSetTime?
      @doSetTime = options.doSetTime.bind(this)
    @process timedGeoJSON if timedGeoJSON?

  intervalFromFeature: (feature) ->
    start: ( new Date feature.properties.start ).getTime()
    end: ( new Date feature.properties.end ).getTime()

  process: (data) ->
    earliestStart = Infinity
    latestEnd = -Infinity
    data.features.forEach (feature) =>
      interval = @intervalFromFeature(feature)
      @ranges.insert interval.start, interval.end, feature
      @times.push interval.start
      @times.push interval.end
      if interval.start < earliestStart then earliestStart = interval.start
      if interval.end > latestEnd then latestEnd = interval.end
    @times = @times.sort (a, b) -> a - b
    @times = @times.reduce((newList, x) ->
      if newList[newList.length - 1] != x
        newList.push x
      return newList
    , [])
    if not @options.start then @options.start = earliestStart
    if not @options.end then @options.end = latestEnd

  addData: (geojson) ->
    # mostly just copied from Leaflet source, because there's no way to get
    # the ID of an added layer. :(
    features = if L.Util.isArray geojson then geojson else geojson.features
    if features
      for feature in features
        # only add this if geometry or geometries are set and not null
        if feature.geometries or feature.geometry or \
            feature.features or feature.coordinates
          @addData feature
      return @
    @_addData(geojson)

  _addData: (geojson) ->
    options = @options
    if options.filter and !options.filter(geojson) then return
    layer = L.GeoJSON.geometryToLayer geojson, options.pointToLayer
    # timeline custom bit here
    @displayedLayers.push
      layer: layer
      geoJSON: geojson
    layer.feature = L.GeoJSON.asFeature geojson
    layer.defaultOptions = layer.options
    @resetStyle layer
    if options.onEachFeature
      options.onEachFeature geojson, layer
    @addLayer layer

  removeLayer: (layer, removeDisplayed = true) ->
    L.GeoJSON.prototype.removeLayer.call this, layer
    if removeDisplayed
      @displayedLayers = @displayedLayers.filter (displayedLayer) ->
        displayedLayer.layer != layer


  setTime: (time) ->
    @time = (new Date time).getTime()
    @doSetTime(time)
    @fire 'change'

  doSetTime: (time) ->
    ranges = @ranges.lookup time
    # inline the JS below because messing with indices
    # and that's ugly in CS
    # seems like a terrible algorithm but I did test it:
    # http://jsperf.com/array-in-place-replace
    # sorted would probably be better if not for the splice insertion
    # maybe using linked lists would be better?
    `var i, j, found;
    for( i = 0; i < this.displayedLayers.length; i++ ){
      found = false;
      for( j = 0; j < ranges.length; j++ ){
        if( this.displayedLayers[i].geoJSON === ranges[j] ){
          found = true;
          ranges.splice(j, 1);
          break;
        }
      }
      if( !found ){
        var to_remove = this.displayedLayers.splice(i--,1);
        this.removeLayer(to_remove[0].layer, false);
      }
    }
    `
    for range in ranges
      @addData range

  onAdd: (map) ->
    L.GeoJSON.prototype.onAdd.call this, map
    @timeSliderControl = L.Timeline.timeSliderControl this
    @timeSliderControl.addTo map

  getDisplayed: -> @ranges.lookup @time


L.Timeline.TimeSliderControl = L.Control.extend
  initialize: (@timeline) ->
    @options.position = @timeline.options.position
    @start = @timeline.options.start
    @end = @timeline.options.end
    @showTicks = @timeline.options.showTicks
    @stepDuration = @timeline.options.duration / @timeline.options.steps
    @stepSize = ( @end - @start ) / @timeline.options.steps

  _buildDataList: (container, times) ->
    @_datalist = L.DomUtil.create 'datalist', '', container
    datalistSelect = L.DomUtil.create 'select', '', @_datalist
    times.forEach (time) ->
      datalistOption = L.DomUtil.create 'option', '', datalistSelect
      datalistOption.value = time
    @_datalist.id = "timeline-datalist-" + Math.floor( Math.random() * 1000000 )
    @_timeSlider.setAttribute 'list', @_datalist.id

  _makePlayPause: (container) ->
    @_playButton = L.DomUtil.create 'button', 'play', container
    @_playButton.addEventListener 'click', => @_play()
    L.DomEvent.disableClickPropagation @_playButton
    @_pauseButton = L.DomUtil.create 'button', 'pause', container
    @_pauseButton.addEventListener 'click', => @_pause()
    L.DomEvent.disableClickPropagation @_pauseButton

  _makePrevNext: (container) ->
    @_prevButton = L.DomUtil.create 'button', 'prev'
    @_nextButton = L.DomUtil.create 'button', 'next'
    @_playButton.parentNode.insertBefore @_prevButton, @_playButton
    @_playButton.parentNode.insertBefore @_nextButton, @_pauseButton.nextSibling
    L.DomEvent.disableClickPropagation @_prevButton
    L.DomEvent.disableClickPropagation @_nextButton
    @_prevButton.addEventListener 'click', @_prev.bind @
    @_nextButton.addEventListener 'click', @_next.bind @

  _makeSlider: (container) ->
    @_timeSlider = L.DomUtil.create 'input', 'time-slider', container
    @_timeSlider.type = "range"
    @_timeSlider.min = @start
    @_timeSlider.max = @end
    @_timeSlider.value = @start
    @_timeSlider.addEventListener 'mousedown', => @map.dragging.disable()
    document.addEventListener     'mouseup',   => @map.dragging.enable()
    @_timeSlider.addEventListener 'input', @_sliderChanged.bind @
    @_timeSlider.addEventListener 'change', @_sliderChanged.bind @

  _makeOutput: (container) ->
    @_output = L.DomUtil.create 'output', 'time-text', container
    @_output.innerHTML = @timeline.options.formatDate new Date @start

  _nearestEventTime: (findTime, mode=0) ->
    retNext = false
    lastTime = @timeline.times[0]
    for time in @timeline.times[1..]
      if retNext then return time
      if time >= findTime
        if mode == -1
          return lastTime
        else if mode == 1
          if time == findTime then retNext = true
          else return time
        else
          prevDiff = Math.abs findTime - lastTime
          nextDiff = Math.abs time - findTime
          return if prevDiff < nextDiff then prevDiff else nextDiff
      lastTime = time
    lastTime

  _prev: ->
    @_pause()
    prevTime = @_nearestEventTime @timeline.time, -1
    @_timeSlider.value = prevTime
    @timeline.setTime prevTime

  _pause: ->
    clearTimeout @_timer
    @container.classList.remove 'playing'

  _play: ->
    clearTimeout @_timer
    if +@_timeSlider.value == @end then @_timeSlider.value = @start
    @_timeSlider.value = +@_timeSlider.value + @stepSize
    @_sliderChanged
      type: 'change'
      target: value: @_timeSlider.value
    unless +@_timeSlider.value == @end
      @container.classList.add 'playing'
      @_timer = setTimeout @_play.bind @, @stepDuration
    else
      @container.classList.remove 'playing'

  _next: ->
    @_pause()
    nextTime = @_nearestEventTime @timeline.time, 1
    @_timeSlider.value = nextTime
    @timeline.setTime nextTime

  _sliderChanged: (e) ->
    time = +e.target.value
    if not @timeline.options.waitToUpdateMap or e.type == 'change'
      @timeline.setTime time
    @_output.innerHTML = @timeline.options.formatDate new Date time

  onAdd: (@map) ->
    container = L.DomUtil.create 'div',
                    'leaflet-control-layers ' +
                    'leaflet-control-layers-expanded ' +
                    'leaflet-timeline-controls'
    if @timeline.options.enablePlayback
      sliderCtrlC = L.DomUtil.create 'div', 'sldr-ctrl-container', container
      buttonContainer = L.DomUtil.create 'div', 'button-container', sliderCtrlC
      @_makePlayPause buttonContainer
      @_makePrevNext buttonContainer
    @_makeSlider container
    @_makeOutput sliderCtrlC
    if @showTicks
      @_buildDataList container, @timeline.times
    @timeline.setTime @start
    @container = container

L.timeline = (timedGeoJSON, options) -> new L.Timeline timedGeoJSON, options
L.Timeline.timeSliderControl = (timeline, start, end, timelist) ->
  new L.Timeline.TimeSliderControl timeline, start, end, timelist
