Freezer = require "freezer-js"
SchemaUtils = require "@smart-fred/editor/lib/helpers/schema-utils"
BundleUtils = require "@smart-fred/editor/lib/helpers/bundle-utils"

$ = require("jquery");

createFreezer = () ->
    freezer = new Freezer
        ui: 
            status: "ready"
        resource: null
        profiles: null
    
    return setupFreezer(freezer)

canMoveNode = (node, parent) ->
	unless parent?.nodeType in ["objectArray", "valueArray"]
		return [false, false]
	index = parent.children.indexOf(node)
	[index>0, index<parent.children.length-1]

findParent = (node, targetNode) ->
	_walkNode = (node) ->
		return unless node.children
		for child, i in node.children
			if child is targetNode
				return [node, i]
			else if child.children
				if result = _walkNode(child)
					return result 
	_walkNode(node)

getSplicePosition = (children, index) ->
	for child, i in children
		if child.index > index
			return i
	return children.length

getChildBySchemaPath = (node, schemaPath) ->
	for child in node.children
		return child if child.schemaPath is schemaPath

getParentById = (node, id) ->
	_walkNode = (node) ->
		return unless node.children
		for child, i in node.children
			if child.id is id
				return [node, i]
			else if child.children
				if result = _walkNode(child)
					return result 
	_walkNode(node)

checkBundle = (json) ->
	json.resourceType is "Bundle" and json.entry

decorateResource = (json, profiles) ->
	return unless SchemaUtils.isResource(profiles, json)
	SchemaUtils.decorateFhirData(profiles, json)

openResource = (state, json) ->
	if decorated = decorateResource(json, state.profiles)
		state.set {resource: decorated, bundle: null}
		return true

openBundle = (state, json) ->
	resources = BundleUtils.parseBundle(json)

	if decorated = decorateResource(resources[0], state.profiles)
		state.pivot()
			.set("bundle", {resources: resources, pos: 0})
			.set({resource: decorated})
		return true

bundleInsert = (state, json, isBundle) ->
	#stop if errors
	[resource, errCount] = 
		SchemaUtils.toFhir state.resource, true
	if errCount isnt 0 
		return state.ui.set("status", "validation_error")
	else
		state.bundle.resources.splice(state.bundle.pos, 1, resource).now()
		#state = State.get()

	resources = if isBundle
		resources = BundleUtils.parseBundle(json)
	else if json.id
		[json]
	else
		nextId = BundleUtils.findNextId(state.bundle.resources)
		json.id = BundleUtils.buildFredId(nextId)
		[json]

	if decorated = decorateResource(resources[0], state.profiles)
		state.pivot()
			.set("resource", decorated)
			.bundle.resources.splice(state.bundle.pos+1, 0, resources...)
			.bundle.set("pos", state.bundle.pos+1)
		return true

replaceContained = (state, json) ->
	if decorated = decorateResource(json, state.profiles)		
		[parent, pos] = getParentById(state.ui.replaceId)
		parent.children.splice(pos, 1, decorated)
		return true

isBundleAndRootId = (bundle, node, parent) ->
	node.fhirType is "id" and bundle and
		parent.level is 0

getResourceType = (node) ->
	for child in node.children
		if child.name is "resourceType"
			return child.value

showReferenceWarning = (state, node, parent, fredId) ->
	prevId = node.ui.prevState.value
	currentId = fredId || node.value
	resourceType = getResourceType(parent)
	prevRef = "#{resourceType}/#{prevId}"
	newRef = "#{resourceType}/#{currentId}"
	changeCount = 
		BundleUtils.countRefs state.bundle.resources, prevRef
	if changeCount > 0
		state.ui.pivot()
			.set(status: "ref_warning") 
			.set(count: changeCount) 
			.set(update: [{from: prevRef, to: newRef }])


setupFreezer = (freezer) ->
	freezer.on "load_initial_json", (profilePath, resourcePath, isRemote) ->
		queue = [
			[profilePath, "set_profiles", "profile_load_error"]
			[resourcePath, "load_json_resource", "resource_load_error"]
		]

		freezer.trigger "set_ui", "loading"
		current = null
		loadNext = ->
			if (current = queue.shift()) and current[0]
				$.ajax 
					url: current[0]
					dataType: "json"
					success: onLoadSuccess
					error: onLoadError		
			else if !isRemote
				freezer.trigger "set_ui", "ready"	
			
		onLoadSuccess = (json) ->
			freezer.trigger current[1], json
			loadNext()

		onLoadError = (xhr, status) ->
			freezer.trigger "set_ui", current[2]	

		loadNext()

	freezer.on "set_profiles", (json) ->
		freezer.get().set
			profiles: json.profiles
			valuesets: json.valuesets

	freezer.on "load_json_resource", (json) =>
		state = freezer.get()
		openMode = state.ui.openMode
		isBundle = checkBundle(json)

		success = if openMode is "insert"
			bundleInsert(state, json, isBundle)
		else if openMode is "contained"
			replaceContained(state, json)
		else if isBundle
			openBundle(state, json)
		else
			openResource(state, json)

		status = if success then "ready" else "resource_load_error"
		state.ui.set("status", "ready")

	freezer.on "set_bundle_pos", (newPos) ->
		state = freezer.get()
		
		#stop if errors
		[resource, errCount] = 
			SchemaUtils.toFhir state.resource, true
		if errCount isnt 0 
			return state.ui.set("status", "validation_error")

		unless decorated = decorateResource(state.bundle.resources[newPos], state.profiles)
			return freezer.trigger "set_ui", "resource_load_error"
		
		state.pivot()
			#splice in any changes
			.set("resource", decorated)
			.bundle.resources.splice(state.bundle.pos, 1, resource)
			.bundle.set("pos", newPos)
			.ui.set(status: "ready")


	freezer.on "remove_from_bundle", ->
		state = freezer.get()
		pos = state.bundle.pos
		newPos = pos+1
		if newPos is state.bundle.resources.length
			pos = newPos = state.bundle.pos-1

		unless decorated = decorateResource(state.bundle.resources[newPos], state.profiles)
			return freezer.trigger "set_ui", "resource_load_error"
		
		state.pivot()
			.set("resource", decorated)
			.bundle.resources.splice(state.bundle.pos, 1)
			.bundle.set("pos", pos)

	freezer.on "clone_resource", ->
		state = freezer.get()

		#stop if errors
		[resource, errCount] = 
			SchemaUtils.toFhir state.resource, true
		if errCount isnt 0 
			return state.ui.set("status", "validation_error")

		resource.id = null
		bundleInsert(state, resource)

	freezer.on "show_open_contained", (node) ->
		freezer.get().ui.pivot()
			.set("status", "open")
			.set("openMode", "contained")
			.set("replaceId", node.id)

	freezer.on "show_open_insert", ->
		freezer.get().ui.pivot()
			.set("status", "open")
			.set("openMode", "insert")

	freezer.on "set_ui", (status, params={}) ->
		freezer.get().ui.set {status: status, params: params}

	freezer.on "value_update", (node, value) ->
		node.ui.reset {status: "ready"}

	freezer.on "value_change", (node, value, validationErr, strictValidationErr) ->
		#in case there are pre-save errors
		freezer.get().ui.set {status: "ready"}

		if node.ui
			node.pivot()
				.set(value: value)
				.ui.set(validationErr: validationErr)
				.now()
		else
			node.pivot()
				.set(value: value)
				.set(ui: {})
				.ui.set(validationErr: validationErr)
				.now()

	freezer.on "start_edit", (node) ->
		node.pivot()
			.set(ui: {})
			.ui.set("status", "editing")
			.ui.set("prevState", node)

	freezer.on "update_refs", (changes) ->
		resources = 
			BundleUtils.fixAllRefs(freezer.get().bundle.resources, changes)

		freezer.get().bundle.set("resources", resources)
		freezer.trigger "set_ui", "ready"

	freezer.on "end_edit", (node, parent) ->
		if isBundleAndRootId(node, parent) and 
			node.value isnt node.ui.prevState.value
				showReferenceWarning(freezer.get(), node, parent)

		node.ui.reset {status: "ready"}

	freezer.on "cancel_edit", (node) ->
		if node.ui.validationErr
			freezer.get().ui.set "status", "ready"
		if node.ui.prevState
			node.reset(node.ui.prevState.toJS())

	freezer.on "delete_node", (node, parent) ->
		if parent.nodeType is "objectArray" and
			parent.children.length is 1
				[targetNode, index] = findParent(node, parent)
		else
			targetNode = parent
			index = parent.children.indexOf(node)

		#don't allow deletion of root level id in bundled resource
		if isBundleAndRootId(node, parent)
			nextId = BundleUtils.findNextId(freezer.get().bundle.resources)
			fredId = BundleUtils.buildFredId(nextId)
			node.pivot()
				.set(value: fredId)
				.ui.set(status: "ready")

			showReferenceWarning(freezer.get(), node, parent, fredId)

		else if index isnt null
			targetNode.children.splice(index, 1)

	freezer.on "move_array_node", (node, parent, down) ->
		position = parent.children.indexOf(node)
		newPostion = if down then position+1 else position-1

		node = node.toJS()
		node.ui.status = "ready"
		parent.children
			.splice(position, 1)
			.splice(newPostion, 0, node)

	freezer.on "show_object_menu", (node, parent) ->
		if node.nodeType isnt "objectArray"
			profiles = freezer.get().profiles
			usedElements = []
			for child in node.children 
				if !child.range or child.range[1] is "1" or child.nodeType is "valueArray" or (
					child.range[1] isnt "*" and parseInt(child.range[1]) < (child?.children?.length || 0)
				)
					usedElements.push child.schemaPath

			fhirType = if node.fhirType is "BackboneElement" then node.schemaPath else node.fhirType 
			unusedElements = SchemaUtils.getElementChildren(profiles, fhirType, usedElements)
		[canMoveUp, canMoveDown] = canMoveNode(node, parent)

		node.pivot()
			.set(ui: {})
			.ui.set(status: "menu")
			.ui.set(menu: {})
			.ui.menu.set(canMoveUp: canMoveUp)
			.ui.menu.set(canMoveDown: canMoveDown)
			.ui.menu.set(unusedElements: unusedElements)


	freezer.on "add_array_value", (node) ->
		profiles = freezer.get().profiles
		newNode = SchemaUtils.buildChildNode(profiles, "valueArray", node.schemaPath, node.fhirType)
		newNode.ui = {status: "editing"}
		node.children.push newNode

	freezer.on "add_array_object", (node) ->
		profiles = freezer.get().profiles
		newNode = SchemaUtils.buildChildNode(profiles, "objectArray", node.schemaPath, node.fhirType)
		node.children.push newNode	

	freezer.on "add_object_element", (node, fhirElement) ->
		profiles = freezer.get().profiles

		if fhirElement.range and fhirElement.range[1] isnt "1" and
			child = getChildBySchemaPath(node, fhirElement.schemaPath)
				newNode = SchemaUtils.buildChildNode(profiles, "objectArray", child.schemaPath, child.fhirType)
				child.children.push newNode			
				return

		newNode = SchemaUtils.buildChildNode(profiles, node.nodeType, fhirElement.schemaPath, fhirElement.fhirType)
		if newNode.nodeType in ["value", "valueArray"]
			newNode.ui = {status: "editing"}
		position = getSplicePosition(node.children, newNode.index)
		node.children.splice(position, 0, newNode)
	
	return freezer

module.exports = createFreezer