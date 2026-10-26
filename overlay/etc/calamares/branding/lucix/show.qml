import QtQuick 2.0
import calamares.slideshow 1.0

Presentation {
    id: presentation

    Slide {
        Rectangle {
            anchors.fill: parent
            color: "#14161c"
        }
        Text {
            anchors.centerIn: parent
            text: "Installing Lucix"
            color: "#ffffff"
            font.pixelSize: 26
        }
    }
}
