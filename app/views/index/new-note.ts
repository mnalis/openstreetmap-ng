import { LngLat, type Map as MaplibreMap, Marker } from "maplibre-gl"
import { setNewNoteButtonState } from "../lib/map/controls/new-note"
import { type FocusLayerPaint, focusObjects } from "../lib/map/layers/focus-layer"
import { type LayerId, layersConfig } from "../lib/map/layers/layers"
import { getMapState, setMapState } from "../lib/map/map-utils"
import { getMarkerIconElement, markerIconAnchor } from "../lib/map/utils"
import { qsParse } from "../lib/qs"
import { configureStandardForm } from "../lib/standard-form"
import { setPageTitle } from "../lib/title"
import { isLatitude, isLongitude } from "../lib/utils"
import { getActionSidebar, switchActionSidebar } from "./_action-sidebar"
import type { IndexController } from "./_router"
import { routerNavigateStrict } from "./_router"

const themeColor = "#f60"
const focusPaint: FocusLayerPaint = Object.freeze({
    "circle-radius": 20,
    "circle-color": themeColor,
    "circle-opacity": 0.5,
    "circle-stroke-color": themeColor,
    "circle-stroke-opacity": 1,
    "circle-stroke-width": 2.5,
})

/** Create a new new note controller */
export const getNewNoteController = (map: MaplibreMap): IndexController => {
    const sidebar = getActionSidebar("new-note")
    const sidebarTitle = sidebar.querySelector(".sidebar-title").textContent
    const form = sidebar.querySelector("form")
    const lonInput = form.elements.namedItem("lon") as HTMLInputElement
    const latInput = form.elements.namedItem("lat") as HTMLInputElement
    const commentInput = form.elements.namedItem("text") as HTMLInputElement
    const submitButton = form.querySelector("button[type=submit]")

    let marker: Marker | null = null

    /** On comment input, update the button state */
    const updateButtonState = () => {
        const hasValue = commentInput.value.trim().length > 0
        submitButton.disabled = !hasValue
    }
    commentInput.addEventListener("input", updateButtonState)

    configureStandardForm(form, ({ note_id }) => {
        // On success callback, navigate to the new note and reload the notes layer
        map.fire("reloadnoteslayer")
        routerNavigateStrict(`/note/${note_id}`)
    })

    return {
        load: () => {
            form.reset()
            switchActionSidebar(map, sidebar)
            setPageTitle(sidebarTitle)

            // Allow default location setting via URL search parameters
            let center: LngLat | null = null
            const searchParams = qsParse(window.location.search)
            if (searchParams.lon && searchParams.lat) {
                const lon = Number.parseFloat(searchParams.lon)
                const lat = Number.parseFloat(searchParams.lat)
                if (isLongitude(lon) && isLatitude(lat)) {
                    center = new LngLat(lon, lat)
                }
            }

            marker = new Marker({
                anchor: markerIconAnchor,
                element: getMarkerIconElement("new", false),
                draggable: true,
            })
                .setLngLat(center ?? map.getCenter())
                .addTo(map)

            const focusHalo = () => {
                const lngLat = marker.getLngLat()
                focusObjects(
                    map,
                    [
                        {
                            type: "note",
                            id: null,
                            geom: [lngLat.lng, lngLat.lat],
                            status: "open",
                            text: "",
                        },
                    ],
                    focusPaint,
                    null,
                    { fitBounds: false },
                )
            }

            const onDragEnd = () => {
                focusHalo()
                const lngLat = marker.getLngLat()
                lonInput.value = lngLat.lng.toString()
                latInput.value = lngLat.lat.toString()
            }

            marker.on("dragstart", () => focusObjects(map)) // hide halo
            marker.on("dragend", onDragEnd) // show halo

            // Initial update
            onDragEnd()
            updateButtonState()
            setNewNoteButtonState(true)

            // Enable notes layer to prevent duplicates
            const state = getMapState(map)
            const notesLayerCode = layersConfig.get("notes" as LayerId).layerCode
            if (!state.layersCode.includes(notesLayerCode)) {
                state.layersCode += notesLayerCode
                setMapState(map, state)
            }
        },
        unload: () => {
            setNewNoteButtonState(false)
            focusObjects(map)
            marker.remove()
            marker = null
        },
    }
}
