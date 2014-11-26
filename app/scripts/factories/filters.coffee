###
Filters service to get current and set filters
###
app = require '../app.coffee'

module.exports =
  app.factory 'Filters'.ourNs(), [ () =>
    
    # query filters 
    values:
    	propertyStatus: [
    		{ label: "For Sale", value:"forSale" },
    		{ label: "Pending", value:"pending" },
    		{ label: "Recently Sold", value:"recentlySold"},
    		{ label: "Not For Sale", value:"notForSale" }
    	],
    	beds:[
        { value: 1, name: "1+" },
        { value: 2, name: "2+" },
        { value: 3, name: "3+" },
        { value: 4, name: "4+" },
        { value: 5, name: "5+" },
        { value: 5, name: "6+" }
      ],
    	baths:[
        { value: 1, name: "1+" },
        { value: 2, name: "2+" },
        { value: 3, name: "3+" },
        { value: 4, name: "4+" },
        { value: 5, name: "5+" },
        { value: 5, name: "6+" }
      ],
    	acresMin:[
        {
          value: 0.1,
          name: ".10 acres"
        },
        {
          value: 0.2,
          name: ".20 acres"
        },
        {
          value: 0.3,
          name: ".30 acres"
        },
        {
          value: 0.4,
          name: ".40 acres"
        },
        {
          value: 0.5,
          name: ".50 acres"
        },
        {
          value: 0.6,
          name: ".60 acres"
        },
        {
          value: 0.7,
          name: ".70 acres"
        },
        {
          value: 0.80,
          name: ".80 acres"
        },
        {
          value: 0.9,
          name: ".90 acres"
        },
        {
          value: 1.0,
          name: "1.0 acres"
        }
      ],
    	acresMax:[
        {
          value: 0.1,
          name: ".10 acres"
        },
        {
          value: 0.2,
          name: ".20 acres"
        },
        {
          value: 0.3,
          name: ".30 acres"
        },
        {
          value: 0.4,
          name: ".40 acres"
        },
        {
          value: 0.5,
          name: ".50 acres"
        },
        {
          value: 0.6,
          name: ".60 acres"
        },
        {
          value: 0.7,
          name: ".70 acres"
        },
        {
          value: 0.80,
          name: ".80 acres"
        },
        {
          value: 0.9,
          name: ".90 acres"
        },
        {
          value: 1.0,
          name: "1.0 acres"
        }
      ]

  ]
