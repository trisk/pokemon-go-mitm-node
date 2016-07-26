###
  Pokemon Go(c) MITM node proxy
  by Michael Strassburger <codepoet@cpan.org>
  This example intercetps the server answer after a successful throw and signals
  the App that the pokemon has fleed - cleaning up can be done at home :)

  Be aware: This triggers an error message in the App but won't interfere further on

  Pokemon Go (c) ManInTheMiddle Radar "mod"
  Michael Strassburger <codepoet@cpan.org>

  Enriches every PokeStop description with information about
  - directions to nearby wild pokemons
  - time left if a PokeStop has an active lure
###

PokemonGoMITM = require './lib/pokemon-go-mitm'
changeCase = require 'change-case'
moment = require 'moment'
LatLon = require('geodesy').LatLonSpherical

pokemons = []
forts = []
currentLocation = null

server = new PokemonGoMITM port: 8081
	# Append the IV% to the end of names in our inventory
	.addResponseHandler "GetInventory", (data) ->
		if data.inventory_delta
			for item in data.inventory_delta.inventory_items when item.inventory_item_data
				if pokemon = item.inventory_item_data.pokemon_data
					name = pokemon.nickname or changeCase.titleCase pokemon.pokemon_id
					atk = pokemon.individual_attack or 0
					def = pokemon.individual_defense or 0
					sta = pokemon.individual_stamina or 0
					iv = Math.round((atk + def + sta) * 100/45)
					pokemon.nickname = "#{name} #{iv}%"

		data
	# Fetch our current location as soon as it gets passed to the API
	.addRequestHandler "GetMapObjects", (data) ->
		currentLocation = new LatLon data.latitude, data.longitude if data.latitude
		if data.latitude
			console.log "[+] Current position of the player #{currentLocation}"

		if not currentLocation
			return false

		for fort in forts when fort.type is 'CHECKPOINT'
			if not fort.cooldown_complete_timestamp_ms or (Date.now() - (parseFloat(fort.cooldown_complete_timestamp_ms)-(3600*2*1000))) >= 300000
				position = new LatLon fort.latitude, fort.longitude
				distance = Math.floor currentLocation.distanceTo position
				fort.cooldown_complete_timestamp_ms = Date.now().toString();
				if distance < 30
					server.craftRequest "FortSearch",
					{
						fort_id: fort.id,
						fort_latitude: fort.latitude,
						fort_longitude: fort.longitude,
						player_latitude: fort.latitude,
						player_longitude: fort.longitude
					}
						.then (data) ->
							if data.result is 'SUCCESS'
								console.log "[<-] Items awarded:", data.items_awarded
		false

	.addResponseHandler "GetMapObjects", (data) ->
		forts = []
		for cell in data.map_cells
			for fort in cell.forts
				forts.push fort
		false
	# Parse the wild pokemons nearby
	.addResponseHandler "GetMapObjects", (data) ->
		pokemons = []
		seen = {}
		addPokemon = (pokemon) ->
			return if seen[hash = pokemon.spawnpoint_id + ":" + pokemon.pokemon_data.pokemon_id]
			return if pokemon.time_till_hidden_ms < 0

			seen[hash] = true
			console.log "new wild pokemon", pokemon
			pokemons.push
				type: pokemon.pokemon_data.pokemon_id
				latitude: pokemon.latitude
				longitude: pokemon.longitude
				expirationMs: Date.now() + pokemon.time_till_hidden_ms
				data: pokemon.pokemon_data

		for cell in data.map_cells
			addPokemon pokemon for pokemon in cell.wild_pokemons

		false

	# Whenever a poke spot is opened, populate it with the radar info!
	.addResponseHandler "FortDetails", (data) ->
		console.log "fetched fort request", data
		info = ""

		# Populate some neat info about the pokemon's whereabouts
		pokemonInfo = (pokemon) ->
			name = changeCase.titleCase pokemon.data.pokemon_id

			position = new LatLon pokemon.latitude, pokemon.longitude
			expires = moment(Number(pokemon.expirationMs)).fromNow()
			distance = Math.floor currentLocation.distanceTo position
			bearing = currentLocation.bearingTo position
			direction = switch true
				when bearing>330 then "↑"
				when bearing>285 then "↖"
				when bearing>240 then "←"
				when bearing>195 then "↙"
				when bearing>150 then "↓"
				when bearing>105 then "↘"
				when bearing>60 then "→"
				when bearing>15 then "↗"
				else "↑"

			"#{name} #{direction} #{distance}m expires #{expires}"

		# Create map marker for pokemon location
		pokemonMarker = (pokemon) ->
			label = pokemon.data.pokemon_id.charAt(0)
			icon = changeCase.paramCase pokemon.data.pokemon_id
			marker = "label:#{label}%7Cicon:http://raw.github.com/msikma/pokesprite/master/icons/pokemon/regular/#{icon}.png"

			"&markers=#{marker}%7C#{pokemon.latitude},#{pokemon.longitude}"

		for modifier in data.modifiers
			if modifier.item_id is 'ITEM_TROY_DISK'
				expires = moment(Number(modifier.expiration_timestamp_ms)).fromNow()
				info += "Lure by #{modifier.deployer_player_codename} expires #{expires}\n"

		info += if pokemons.length and currentLocation
			(pokemonInfo(pokemon) for pokemon in pokemons).join "\n"
		else
			"No wild Pokémon near you..."

		data.description = info

		if currentLocation
			img = "http://maps.googleapis.com/maps/api/staticmap?center=#{currentLocation.lat},#{currentLocation.lon}&zoom=17&size=384x512"

			if pokemons.length
				img += (pokemonMarker(pokemon) for pokemon in pokemons).join ""

			data.image_urls = [ img ]
		data

	# Get encounter info
	.addResponseHandler "Encounter", (data) ->
		console.log "encounter with pokemon", data

	.addRequestHandler "CatchPokemon", (data) ->
		console.log "trying to catch pokemon", data
		if data.spin_modifier < 0.85
			data.spin_modifier = 0.80 + data.spin_modifier % 0.10
		if data.normalized_reticle_size < 1.95
			data.normalized_reticle_size = 1.90 + data.normalized_reticle_size % 0.10
		if data.hit_pokemon
			data.normalized_hit_position = 1.0
		data

	# Replace successful catch with escape to save time
	.addResponseHandler "CatchPokemon", (data) ->
		console.log "tried to catch pokemon", data
		data.status = 'CATCH_FLEE' if data.status is 'CATCH_SUCCESS'
		data

