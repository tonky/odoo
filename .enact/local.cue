package replay

pipeline: {
	workflows: {
		local: {
			layout:   "staged"
			services: "on_demand"
			stages:   _stages
		}
	}
}
