set(PLUGIN_NAME ble_controller_glue)

add_library(${PLUGIN_NAME} STATIC
    ${CMAKE_CURRENT_LIST_DIR}/ble_bridge.cpp
)

target_link_libraries(${PLUGIN_NAME} PRIVATE ${ENGINE_NAME})
target_include_directories(${PLUGIN_NAME} PUBLIC ${CMAKE_CURRENT_LIST_DIR})

if(WINDOWS AND EXISTS "${CMAKE_CURRENT_LIST_DIR}/bin")
    set(OUTPUT_DIR "$<TARGET_FILE_DIR:${PLUGIN_NAME}>")
    add_custom_command(TARGET ${PLUGIN_NAME} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_CURRENT_LIST_DIR}/bin"
        "${OUTPUT_DIR}"
        COMMENT "Copying BLE Server files to: ${OUTPUT_DIR}"
    )
endif()
