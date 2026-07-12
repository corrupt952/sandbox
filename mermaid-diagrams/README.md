# mermaid-diagrams

Trying out [Mermaid](https://mermaid.js.org/) diagram syntax. The samples below
render natively on GitHub; `index.html` is a standalone page that renders the
basic flowchart via the Mermaid CDN build.

## Flowchart

```mermaid
graph TD
    A-->B
    A-->C
    B-->D
    C-->D
```

## Sequence diagram

```mermaid
sequenceDiagram
    participant Alice
    participant Bob
    Alice->>John: Hello John, how are you?
    loop Healthcheck
        John->>John: Fight against hypochondria
    end
    Note right of John: Rational thoughts <br/>prevail!
    John-->>Alice: Great!
    John->>Bob: How about you?
    Bob-->>John: Jolly good!
```

## Pie chart

```mermaid
pie title NETFLIX
         "Time spent looking for movie" : 90
         "Time spent watching it" : 10
```

## Gantt chart

```mermaid
gantt
dateFormat  YYYY-MM-DD
title Adding GANTT diagram to mermaid
excludes weekdays 2014-01-10

section A section
Completed task            :done,    des1, 2014-01-06,2014-01-08
Active task               :active,  des2, 2014-01-09, 3d
Future task               :         des3, after des2, 5d
Future task2               :         des4, after des3, 5d
```

## Class diagram

```mermaid
classDiagram
Class01 <|-- AveryLongClass : Cool
Class03 *-- Class04
Class05 o-- Class06
Class07 .. Class08
Class09 --> C2 : Where am i?
Class09 --* C3
Class09 --|> Class07
Class07 : equals()
Class07 : Object[] elementData
Class01 : size()
Class01 : int chimp
Class01 : int gorilla
Class08 <--> C2: Cool label
```

## GitGraph

```mermaid
gitGraph:
options
{
    "nodeSpacing": 150,
    "nodeRadius": 10
}
end
commit
branch newbranch
checkout newbranch
commit
commit
checkout master
commit
commit
merge newbranch
```

## Architecture-style diagram

```mermaid
graph LR
    User --> Nginx
    User --> CF[CloudFront]
    subgraph AWS
        subgraph EC2
            Nginx --> Puma
            Puma --> db[(MySQL)]
            Puma --> cache[(Redis)]
        end

        CF --> S3
    end
```

## Notes

- `index.html` pins Mermaid 8.14.0 from the CDN.
- The GitGraph sample uses the old `gitGraph:` + `options { ... } end` syntax,
  which newer Mermaid versions no longer accept.
